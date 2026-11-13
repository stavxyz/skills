#!/usr/bin/env bash
# test-no-positional-tokens.sh: no skill body may contain a positional token.
#
# Claude Code replaces `$N` and `$ARGUMENTS[N]` in a skill body with the Nth
# argument of the invocation (0-based), including inside inline code. A token
# with no argument at its index is left as written, so the damage only shows
# when a call carries enough arguments: polish-pr quoted an awk program that
# printed field two, and a three-argument call rendered it as the third
# argument. That went unnoticed for months of one-argument calls.
#
# A token escaped with a backslash is left alone by Claude Code and passes here.
#
# Usage: tests/skill-bodies/test-no-positional-tokens.sh [file...]
#        (no arguments: every SKILL.md and validate reviewer template)
# Exit:  0 none found, 1 otherwise.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [ $# -gt 0 ]; then
  files=("$@")
else
  files=("$ROOT"/skills/*/SKILL.md "$ROOT"/skills/validate/*-reviewer.md)
fi

# The pattern is a literal regex, so the dollar signs must not expand.
# shellcheck disable=SC2016
hits=$(grep -nE '(^|[^\\])\$([0-9]|ARGUMENTS\[)' "${files[@]}")
if [ -n "$hits" ]; then
  printf 'FAIL: positional tokens in skill bodies (argument substitution will replace them):\n%s\n' "$hits"
  exit 1
fi
printf 'ok: no positional tokens in %d skill bodies\n' "${#files[@]}"
