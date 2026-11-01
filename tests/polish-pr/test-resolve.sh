#!/usr/bin/env bash
# test-resolve.sh: URL-normalization fixtures for resolve-pr-remotes.sh.
#
# The normalizer is the part that silently returns a wrong answer when it is
# wrong: an unmatched form falls through to "no remote hosts the base repo",
# and the earlier inline version simply defaulted to `origin` instead. Every
# URL dialect git accepts gets a fixture here.
#
# Usage: tests/polish-pr/test-resolve.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/polish-pr" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-pr-remotes.sh"

pass=0
fail=0

check() {
  local desc=$1 url=$2 want=$3 got
  got=$("$RESOLVE" --normalize "$url")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  url:  %s\n  want: %s\n  got:  %s\n' "$desc" "$url" "$want" "$got"
  fi
}

T=github.com/acme/widgets

check "scp-style with .git"        'git@github.com:acme/widgets.git'          "$T"
check "scp-style without .git"     'git@github.com:acme/widgets'              "$T"
check "https with .git"            'https://github.com/acme/widgets.git'      "$T"
check "https without .git"         'https://github.com/acme/widgets'          "$T"
check "https trailing slash"       'https://github.com/acme/widgets/'         "$T"
check "http scheme"                'http://github.com/acme/widgets.git'       "$T"
check "ssh:// (insteadOf rewrite)" 'ssh://git@github.com/acme/widgets.git'    "$T"
check "ssh:// without user"        'ssh://github.com/acme/widgets.git'        "$T"
check "ssh:// with port"           'ssh://git@github.com:2222/acme/widgets.git' "$T"
check "git:// protocol"            'git://github.com/acme/widgets.git'        "$T"
check "https with credentials"     'https://user:tok@github.com/acme/widgets' "$T"
check "https with port"            'https://github.com:8443/acme/widgets.git' "$T"
check "uppercase is folded"        'git@GitHub.com:Acme/Widgets.git'          "$T"

# Host is retained, so an enterprise remote must NOT collide with github.com.
check "GHE host retained"          'https://ghe.corp.example/acme/widgets.git' \
                                   'ghe.corp.example/acme/widgets'
check "GHE scp-style"              'git@ghe.corp.example:acme/widgets.git' \
                                   'ghe.corp.example/acme/widgets'

# Local paths have no host; they normalize to themselves and therefore never
# match a real target, which surfaces as a loud "no remote hosts…" exit 1.
check "local path with a space"    '/Users/x/My Repos/widgets'  '/users/x/my repos/widgets'

# ---- The REST fallback. --------------------------------------------------
#
# `gh pr view --json` is GraphQL, and some sandboxed sessions' proxies refuse
# GraphQL while REST goes through (Claude Code's cloud sessions: a 403 on every
# GraphQL call, whatever the token). The script then reads the pull request
# over REST. gh is replaced by a stub whose `pr view` fails the way the proxy
# does and whose `api` answers with a pull-request body, so the whole path
# runs with no network, inside a scratch repository whose remotes are known.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
# $GH_STUB_MODE: graphql-403 (pr view fails, api answers), both-fail, head-gone
# $GH_STUB_CALLS collects one line per invocation, with GH_REPO if set.
printf '%s GH_REPO=%s\n' "$1 $2" "${GH_REPO:-}" >> "$GH_STUB_CALLS"
case "$1 $2" in
  "pr view")
    echo "GraphQL: Error: HTTP 403: Forbidden (https://api.github.com/graphql)" >&2
    exit 1 ;;
  "api repos/{owner}/{repo}/pulls/7")
    case "$GH_STUB_MODE" in
      both-fail) echo "HTTP 404: Not Found (https://api.github.com/repos/x/y/pulls/7)" >&2; exit 1 ;;
      head-gone) printf '%s\n' "https://github.com/parconditio/grocerbot/pull/7" main "" true ;;
      *)         printf '%s\n' "https://github.com/parconditio/grocerbot/pull/7" main stavxyz/grocerbot true ;;
    esac ;;
  *) echo "stub: unexpected call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$tmp/gh"

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" remote add upstream https://github.com/parconditio/grocerbot.git
git -C "$repo" remote add origin git@github.com:stavxyz/grocerbot.git

# resolve_rest <desc> <mode> <want-exit> <want-stdout-substring|-> <want-stderr-substring|-> [args...]
resolve_rest() {
  local desc=$1 mode=$2 want=$3 want_out=$4 want_err=$5; shift 5
  : > "$tmp/calls"
  local out err got
  out=$(cd "$repo" && GH_STUB_MODE="$mode" GH_STUB_CALLS="$tmp/calls" RESOLVE_PR_REMOTES_GH="$tmp/gh" \
        "$RESOLVE" 7 "$@" 2>"$tmp/err")
  got=$?
  err=$(cat "$tmp/err")
  if [ "$got" = "$want" ] \
     && { [ "$want_out" = "-" ] || grep -qF "$want_out" <<<"$out"; } \
     && { [ "$want_err" = "-" ] || grep -qF "$want_err" <<<"$err"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want exit %s, stdout containing %s, stderr containing %s\n  got exit %s\n  stdout:\n%s\n  stderr:\n%s\n' \
      "$desc" "$want" "$want_out" "$want_err" "$got" "$out" "$err"
  fi
}

resolve_rest "GraphQL refused: the base remote comes from REST" graphql-403 0 \
  "BASE_REMOTE=upstream" "read the pull request over the REST API instead"
resolve_rest "GraphQL refused: the head remote comes from REST" graphql-403 0 \
  "HEAD_REMOTE=origin" -
resolve_rest "GraphQL refused: cross-repository is carried through" graphql-403 0 \
  "CROSS_REPOSITORY=true" -
resolve_rest "GraphQL refused: the base branch is carried through" graphql-403 0 \
  "BASE_BRANCH=main" -
resolve_rest "the switch names the GraphQL failure" graphql-403 0 \
  - "HTTP 403"
resolve_rest "both transports failing is exit 3 with both messages" both-fail 3 \
  - "HTTP 404"
resolve_rest "a deleted head fork is a hard stop, not an empty remote" head-gone 3 \
  - "no head repository"

# --repo must reach the REST call as GH_REPO, or the fallback could read a
# same-numbered PR in whichever repository gh resolves on its own.
: > "$tmp/calls"
(cd "$repo" && GH_STUB_MODE=graphql-403 GH_STUB_CALLS="$tmp/calls" RESOLVE_PR_REMOTES_GH="$tmp/gh" \
   "$RESOLVE" 7 --repo parconditio/grocerbot >/dev/null 2>&1)
if grep -qF "api repos/{owner}/{repo}/pulls/7 GH_REPO=parconditio/grocerbot" "$tmp/calls"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL: --repo did not reach the REST call as GH_REPO; calls were:\n%s\n' "$(cat "$tmp/calls")"
fi

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d normalization and REST-fallback cases passed\n' "$pass"
  exit 0
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit 1
