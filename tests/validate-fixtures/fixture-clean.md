---
type: spec
---

# Clean fixture — synthetic test for /validate

**Status:** Synthetic test fixture for /validate prompt regression.
**Date:** 2026-05-08

## Goal

This fixture is a minimal, accurate spec used to confirm that /validate produces few/no findings on a clean input. It references real files in this repository at known-stable line ranges and proposes no changes.

## Architecture

The existing utility module `admin/app/src/lib/rel-time.ts` exports a function `relTime` that returns human-readable relative timestamps like "5 minutes ago" or "3 days ago." This fixture acknowledges the function exists at that path and proposes no changes to it.

## Components

- `admin/app/src/lib/rel-time.ts` — already contains `relTime`. No changes proposed.
- `admin/app/src/components/sentinel/SourceList.tsx` — imports `relTime` from `../../lib/rel-time` near the top of the file. No changes proposed.

## Out of scope

This fixture deliberately makes no design proposals. Its purpose is to be a no-op input that should produce zero net-negative findings and ideally zero Critical/Important findings overall. A few Low-severity advisories from the SOLID reviewer are acceptable (the spec's narrowness is itself reviewable).
