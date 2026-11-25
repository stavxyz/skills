#!/usr/bin/env bash
# probe-rest-fallback-live.sh: does wait-for-pr-checks.sh give the same answer
# over REST as over GraphQL, on real pull requests?
#
# test-wait-for-checks.sh covers the watcher's decisions with a stubbed gh.
# This runs it twice against the real API for each PR: once with plain gh
# pinned to GraphQL, and once behind a wrapper that refuses `gh pr view` and
# `gh pr checks` with a 403 the way a GraphQL-blocking proxy does (Claude
# Code's cloud sessions) and passes every other call through. It then compares
# the exit code and the rows. It is a simulation: it cannot show that a real
# proxy lets the REST calls through.
#
# Usage:
#   tests/polish-pr/probe-rest-fallback-live.sh [--script PATH] <owner/repo#N>...
#
#   --script  the wait-for-pr-checks.sh to run (default: this repository's
#             copy; pass an installed plugin's copy to check what is deployed)
#
# It only reads. Pick PRs whose checks have settled; one still running can
# change between the two runs. Run it after any change to how the watcher
# reads checks or the PR's head.
#
# Exit: 0 every PR gave the same exit code on both transports and REST showed
# every row GraphQL showed with the same bucket (REST may list more rows; the
# extra ones are printed); 1 a difference, or a PR that could not be read; 3
# usage.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$ROOT/skills/polish-pr/wait-for-pr-checks.sh"
targets=()
usage() { awk '/^# Usage:/{on=1} on && !/^#/{exit} on' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 3; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) [[ $# -ge 2 ]] || usage; script="$2"; shift 2 ;;
    -h|--help) awk '/^# Usage:/{on=1} on && !/^#/{exit} on' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) targets+=("$1"); shift ;;
  esac
done
[[ -f "$script" ]] || { echo "no such script: $script" >&2; exit 3; }
script="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"
[[ ${#targets[@]} -gt 0 ]] || usage
for t in "${targets[@]}"; do
  [[ "$t" =~ ^[^#/]+/[^#/]+#[0-9]+$ ]] || { echo "not owner/repo#N: $t" >&2; usage; }
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
real_gh="$(command -v gh)" || { echo "gh is not on PATH" >&2; exit 3; }
cat > "$tmp/gh" <<WRAP
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view"|"pr checks") echo "GraphQL: Error: HTTP 403: Forbidden (https://api.github.com/graphql)" >&2; exit 1 ;;
esac
exec "$real_gh" "\$@"
WRAP
chmod +x "$tmp/gh"

bad=0
for t in "${targets[@]}"; do
  repo="${t%%#*}"; n="${t##*#}"
  GH_REPO="$repo" WAIT_FOR_PR_CHECKS_TRANSPORT=graphql bash "$script" "$n" --settle 0 --timeout 0 >"$tmp/plain" 2>"$tmp/plain.err"; prc=$?
  GH_REPO="$repo" WAIT_FOR_PR_CHECKS_GH="$tmp/gh" bash "$script" "$n" --settle 0 --timeout 0 >"$tmp/proxy" 2>"$tmp/proxy.err"; xrc=$?
  if [[ "$prc" == 3 || "$xrc" == 3 ]]; then
    bad=1; echo "FAIL $t: could not be read (graphql exit $prc, rest exit $xrc): $(tail -n 1 "$tmp/plain.err") / $(tail -n 1 "$tmp/proxy.err")"
    continue
  fi
  grep -v '^VERDICT: ' "$tmp/plain" | sort > "$tmp/plain.rows"
  grep -v '^VERDICT: ' "$tmp/proxy" | sort > "$tmp/proxy.rows"
  missing="$(comm -23 "$tmp/plain.rows" "$tmp/proxy.rows")"
  extra="$(comm -13 "$tmp/plain.rows" "$tmp/proxy.rows")"
  rows="$(grep -c . "$tmp/plain.rows")"
  if [[ "$prc" != "$xrc" || -n "$missing" ]]; then
    bad=1; echo "FAIL $t: graphql exit $prc, rest exit $xrc"
    [[ -n "$missing" ]] && printf '   only over graphql: %s\n' "$missing"
  else
    echo "ok   $t: exit $prc on both, $rows row(s) over graphql all present over rest"
  fi
  [[ -n "$extra" ]] && printf '   only over rest: %s\n' "$extra"
done
exit "$bad"
