#!/usr/bin/env bash
# test-resolve.sh — URL-normalization fixtures for resolve-pr-remotes.sh.
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

if [ "$fail" -eq 0 ]; then
  printf 'ok — %d normalization cases passed\n' "$pass"
  exit 0
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit 1
