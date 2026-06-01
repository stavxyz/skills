---
type: spec
---

# Drift fixture — synthetic test for /validate

**Status:** Synthetic test fixture for /validate prompt regression.
**Date:** 2026-05-08

## Goal

This fixture deliberately references outdated file paths, renamed functions, and moved line ranges to verify the fact-check reviewer catches drift. None of the references in this fixture should resolve cleanly against the current working tree at HEAD.

## Architecture

Modify `admin/old-app/src/legacy/sentinel-changes.ts` to add a `parseLegacyChange(detail: any): LegacyChange` function. The function should be inserted at line 42, between the existing `LegacyChange` type definition and the existing `assertLegacyChange` helper.

The existing function `oldRelativeTime` exported from `admin/app/src/lib/rel-time.ts` should be renamed to `relTimeV2`. All callers will need to be updated.

## Components

- `admin/old-app/src/legacy/sentinel-changes.ts:42-58` — currently contains the `LegacyChange` type definition and the `assertLegacyChange` helper.
- `admin/app/src/lib/rel-time.ts:99` — contains the `oldRelativeTime` export.

## Expected drift

This fixture is intentionally synthetic. The fact-check reviewer should produce at least 3 drift findings:

1. `admin/old-app/` does not exist anywhere in the repo.
2. There is no function named `oldRelativeTime` in `rel-time.ts` (the function is named `relTime`).
3. Line 99 of `rel-time.ts` is past EOF (the file is much shorter).

The SOLID reviewer should produce few or no findings — the proposed design has no SOLID story (it's just a rename and a function add), but it doesn't make anything actively worse, so net-negative findings are not expected.
