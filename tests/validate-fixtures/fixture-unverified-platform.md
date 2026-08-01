---
type: spec
---

# nightly-cache-warmer — design

## Problem

The first CI build of the morning runs against cold caches and takes ~3×
as long as later builds. Warming the caches before the workday starts
removes the penalty.

## Approach

A `launchd` job runs `warm-cache.sh` daily at 05:00. Because launchd
guarantees that calendar jobs missed while the machine was powered off are
always executed immediately at the next boot, the warmer needs no catch-up
logic of its own — a laptop shut overnight still warms its caches first
thing in the morning.

The script reads its repo list from `tests/validate-fixtures/` (this
directory exists in this repo) and warms each entry serially.

## Error handling

Failures are logged to syslog and never retried; the next scheduled run is
the retry.
