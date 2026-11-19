#!/usr/bin/env bash
# test-reword-commits.sh: fixtures for skills/polish-pr/reword-commits.py.
#
# The helper rewrites history, so the cases that matter most are the ones that
# must leave the branch exactly where it was: an edit that matches no commit,
# two commits, or two places in one message; a subject a --drop-lines pattern
# would delete; a merge in the range; a detached HEAD; a dry run; and a branch
# that moved while the helper was working. Each of those asserts the branch tip
# is unchanged. The cases that do rewrite assert that every commit keeps its
# tree, author, and author date, and that commits older than the first change
# keep their shas.
#
# Every case builds its own repository under a temporary directory with a
# fixed author and fixed dates. Global and system git config are switched off
# so a signing key, a hooks path, or a commit template on the machine running
# the tests cannot change the outcome.
#
# Usage: tests/polish-pr/test-reword-commits.sh
# Exit:  0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/polish-pr" && pwd)
RW="$SCRIPT_DIR/reword-commits.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Ada Example" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Cy Example" GIT_COMMITTER_EMAIL="cy@example.com"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; }

n=0
# commit <dir> <day> <file> <message>: one commit with fixed dates.
commit() {
  local dir=$1 day=$2 file=$3 msg=$4
  echo "$day $file" >> "$dir/$file"
  git -C "$dir" add "$file"
  printf '%s' "$msg" > "$tmp/msg"
  GIT_AUTHOR_DATE="2026-01-$day 10:00:00 +0200" GIT_COMMITTER_DATE="2026-01-$day 11:00:00 +0000" \
    git -C "$dir" commit -q -F "$tmp/msg"
}

# mkrepo: a repository with a base commit tagged `base` and three commits on
# main above it. Sets $R.
mkrepo() {
  n=$((n + 1))
  R="$tmp/repo$n"
  mkdir -p "$R"
  git -C "$R" init -q -b main
  commit "$R" 01 base.txt "chore: initial"
  git -C "$R" tag base
  commit "$R" 02 a.txt "feat: add widget

Adds the widget.

Co-Authored-By: Example Bot <bot@example.com>
"
  commit "$R" 03 b.txt "fix: widget retries

The widget retries twice.

Co-Authored-By: Example Bot <bot@example.com>
"
  commit "$R" 04 c.txt "docs: widget notes

Mentions the note and the note again.
"
}

# rw <args...>: run the helper inside $R; sets $out and $got.
rw() {
  out=$(cd "$R" && python3 "$RW" "$@" 2>&1)
  got=$?
}

check() {
  local desc=$1 want=$2 want_out=${3:-}
  if [ "$got" = "$want" ] && { [ -z "$want_out" ] || grep -qF -- "$want_out" <<<"$out"; }; then
    ok
  else
    bad "$desc" "  want exit $want${want_out:+ and output containing: $want_out}
  got exit $got, output:
$out"
  fi
}

tip() { git -C "$R" rev-parse refs/heads/main; }
msg() { git -C "$R" cat-file commit "$1" | sed '1,/^$/d'; }
# identity: tree, author name, email, and raw author date, oldest first.
identity() { git -C "$R" log --reverse --format='%T %an <%ae> %ad' --date=raw base..main; }
shas() { git -C "$R" rev-list --reverse base..main; }
rescue_refs() { git -C "$R" for-each-ref --format='%(refname) %(objectname)' refs/rescue/; }

unchanged() {
  local desc=$1 before=$2
  if [ "$(tip)" = "$before" ]; then ok; else bad "$desc: the branch must not move" "before $before, after $(tip)"; fi
  if [ -z "$(rescue_refs)" ]; then ok; else bad "$desc: no rescue ref is written" "$(rescue_refs)"; fi
}

json() { printf '%s' "$1" > "$tmp/replace.json"; }

# --- one replacement ----------------------------------------------------------
mkrepo
before_tip=$(tip)
before_ids=$(identity)
read -r c1 c2 c3 < <(shas | tr '\n' ' ')
echo "local edit" >> "$R/a.txt"
echo "scratch" > "$R/untracked.txt"
status_before=$(git -C "$R" status --porcelain)
json '[{"old": "retries twice", "new": "retries three times"}]'
rw --base base --replace "$tmp/replace.json"
check "one replacement rewrites the branch" 0
read -r n1 n2 n3 < <(shas | tr '\n' ' ')
if [ "$(msg "$n2")" = "fix: widget retries

The widget retries three times.

Co-Authored-By: Example Bot <bot@example.com>" ]; then ok; else bad "the targeted message is edited" "$(msg "$n2")"; fi
if [ "$(msg "$n3")" = "$(msg "$c3")" ]; then ok; else bad "a later commit keeps its message" "$(msg "$n3")"; fi
if [ "$(identity)" = "$before_ids" ]; then ok; else bad "every tree, author, and author date is unchanged" "before:
$before_ids
after:
$(identity)"; fi
if [ "$n1" = "$c1" ]; then ok; else bad "a commit older than the changed one keeps its sha" "$c1 -> $n1"; fi
if [ "$n2" != "$c2" ] && [ "$n3" != "$c3" ]; then ok; else bad "the changed commit and its descendants get new shas"; fi
short=$(git -C "$R" rev-parse --short "$before_tip")
if [ "$(git -C "$R" rev-parse "refs/rescue/reword/main/$short" 2>/dev/null)" = "$before_tip" ]; then ok; else bad "the rescue ref points at the old tip" "$(rescue_refs)"; fi
check "the rescue ref is announced" 0 "refs/rescue/reword/main/$short"
# Without --remote-tip the helper cannot know what the remote holds, so the
# lease is a placeholder with a line saying what goes there.
check "without --remote-tip the push command carries a placeholder" 0 "git push --force-with-lease=main:<remote-tip> <remote> HEAD:main"
check "the placeholder is explained" 0 "<remote-tip> is the sha the remote branch held"
if grep -qF -- "--force-with-lease=main:$before_tip" <<<"$out"; then
  bad "the local old tip must not be offered as the lease" "$out"
else
  ok
fi
check "the table shows the new short sha" 0 "$(git -C "$R" rev-parse --short "$n2")"
if [ "$(git -C "$R" status --porcelain)" = "$status_before" ] && grep -q "local edit" "$R/a.txt" && [ -f "$R/untracked.txt" ]; then
  ok
else
  bad "uncommitted changes survive the rewrite" "$(git -C "$R" status --porcelain)"
fi
if [ "$(git -C "$R" symbolic-ref HEAD)" = "refs/heads/main" ]; then ok; else bad "HEAD stays on the branch"; fi

# --- refusals leave the branch where it was ----------------------------------
mkrepo; t=$(tip)
json '[{"old": "no such text", "new": "x"}]'
rw --base base --replace "$tmp/replace.json"
check "a replacement that matches no commit is refused" 1 "no commit"
unchanged "no match" "$t"

mkrepo; t=$(tip)
json '[{"old": "Example Bot", "new": "Example Person"}]'
rw --base base --replace "$tmp/replace.json"
check "a replacement that matches two commits is refused" 1 "2 commits"
check "the refusal lists what matched" 1 "feat: add widget"
unchanged "two commits" "$t"

mkrepo; t=$(tip)
json '[{"old": "the note", "new": "a note"}]'
rw --base base --replace "$tmp/replace.json"
check "text that occurs twice in one message is refused" 1 "2 times"
unchanged "two occurrences" "$t"

mkrepo; t=$(tip)
python3 -c 'import json,sys; json.dump([{"old": "docs: widget notes\n\nMentions the note and the note again.\n", "new": ""}], open(sys.argv[1], "w"))' "$tmp/replace.json"
rw --base base --replace "$tmp/replace.json"
check "a message that would become empty is refused" 1 "empty"
unchanged "empty message" "$t"

# --- subject_prefix and every -------------------------------------------------
mkrepo; read -r c1 c2 c3 < <(shas | tr '\n' ' ')
json '[{"old": "Example Bot", "new": "Example Person", "subject_prefix": "fix:"}]'
rw --base base --replace "$tmp/replace.json"
check "subject_prefix narrows to one commit" 0
read -r n1 n2 n3 < <(shas | tr '\n' ' ')
if [ "$n1" = "$c1" ] && msg "$n2" | grep -q "Example Person" && msg "$n1" | grep -q "Example Bot"; then
  ok
else
  bad "only the commit whose subject starts with the prefix is edited" "$(msg "$n1"; echo ---; msg "$n2")"
fi

mkrepo; before_ids=$(identity)
json '[{"old": "widget", "new": "gadget", "every": true}]'
rw --base base --replace "$tmp/replace.json"
check "every: true is accepted across commits" 0
all=$(for s in $(shas); do msg "$s"; done)
if ! grep -q widget <<<"$all" && [ "$(grep -o gadget <<<"$all" | wc -l | tr -d ' ')" = "5" ]; then
  ok
else
  bad "every: true changes every occurrence" "$all"
fi
if [ "$(identity)" = "$before_ids" ]; then ok; else bad "every: trees and authors unchanged"; fi

mkrepo; t=$(tip)
json '[{"old": "no such text", "new": "x", "every": true}]'
rw --base base --replace "$tmp/replace.json"
check "every: true that matches nothing is refused" 1 "no commit"
unchanged "every with no match" "$t"

# --- --drop-lines -------------------------------------------------------------
mkrepo; before_ids=$(identity); read -r c1 c2 c3 < <(shas | tr '\n' ' ')
rw --base base --drop-lines '^Co-Authored-By:'
check "--drop-lines removes a trailer from several commits" 0
read -r n1 n2 n3 < <(shas | tr '\n' ' ')
want1=$'feat: add widget\n\nAdds the widget.'
want2=$'fix: widget retries\n\nThe widget retries twice.'
# $(...) strips trailing newlines, so compare the raw tail separately.
if [ "$(msg "$n1")" = "$want1" ] && [ "$(msg "$n2")" = "$want2" ]; then ok; else bad "the trailer lines are gone" "$(msg "$n1"; echo ---; msg "$n2")"; fi
for s in "$n1" "$n2"; do
  tail2=$(git -C "$R" cat-file commit "$s" | tail -c 2 | od -An -c | tr -d ' ')
  if [ "$tail2" = '.\n' ]; then ok; else bad "no trailing blank line is left in $s" "last two bytes: $tail2"; fi
done
if [ "$(identity)" = "$before_ids" ]; then ok; else bad "drop-lines: trees and authors unchanged"; fi

# The attribution sweep's patterns include an emoji; a message is UTF-8 bytes,
# so a non-ASCII line must match and the rest of the message must survive.
mkrepo
commit "$R" 05 e.txt "feat: café menu

Adds the café menu.

🤖 Generated with an example tool
"
rw --base base --drop-lines '🤖 Generated with' --drop-lines '^Co-Authored-By:'
check "a non-ASCII pattern drops a non-ASCII line" 0
if [ "$(msg "$(tip)")" = $'feat: café menu\n\nAdds the café menu.' ]; then ok; else bad "the non-ASCII message survives byte for byte" "$(msg "$(tip)")"; fi

mkrepo; t=$(tip)
rw --base base --drop-lines '^feat:'
check "a pattern that matches a subject is refused" 1 "subject"
unchanged "subject pattern" "$t"

mkrepo; t=$(tip)
rw --base base --drop-lines '^No such line'
check "nothing to change exits 0" 0 "nothing to change"
unchanged "nothing to change" "$t"

# --- range refusals -----------------------------------------------------------
mkrepo
git -C "$R" checkout -q -b side base
commit "$R" 05 d.txt "feat: side work"
git -C "$R" checkout -q main
GIT_AUTHOR_DATE="2026-01-06 10:00:00 +0000" GIT_COMMITTER_DATE="2026-01-06 10:00:00 +0000" \
  git -C "$R" merge -q --no-ff -m "Merge branch side" side
t=$(tip)
rw --base base --drop-lines '^Co-Authored-By:'
check "a merge commit in the range is refused" 1 "merge"
unchanged "merge in range" "$t"

mkrepo
git -C "$R" checkout -q --detach
t=$(tip)
rw --base base --drop-lines '^Co-Authored-By:'
check "a detached HEAD is refused" 1 "detached"
unchanged "detached HEAD" "$t"

mkrepo; t=$(tip)
rw --base main --drop-lines '^Co-Authored-By:'
check "an empty range is refused" 1 "empty"
unchanged "empty range" "$t"

# --- dry run ------------------------------------------------------------------
mkrepo; t=$(tip)
json '[{"old": "retries twice", "new": "retries three times"}]'
rw --base base --replace "$tmp/replace.json" --dry-run
check "--dry-run exits 0" 0
check "--dry-run shows the removed line" 0 "-The widget retries twice."
check "--dry-run shows the added line" 0 "+The widget retries three times."
unchanged "dry run" "$t"

# --- a branch that moves during the rewrite is not overwritten ---------------
# A git wrapper first on PATH commits onto the branch just before the helper's
# first update-ref runs, which is the race the expected-value argument exists
# for. The rescue ref and the branch move are one transaction, so the refusal
# must leave no rescue ref behind either.
mkrepo
real_git=$(command -v git)
mkdir -p "$tmp/wrap"
cat > "$tmp/wrap/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = "update-ref" ] && [ ! -e "$tmp/raced" ]; then
  touch "$tmp/raced"
  echo race >> race.txt
  "$real_git" add race.txt
  "$real_git" commit -q -m "chore: someone else's commit"
fi
exec "$real_git" "\$@"
WRAP
chmod +x "$tmp/wrap/git"
json '[{"old": "retries twice", "new": "retries three times"}]'
out=$(cd "$R" && PATH="$tmp/wrap:$PATH" python3 "$RW" --base base --replace "$tmp/replace.json" 2>&1); got=$?
check "a branch that moved before the update is refused" 1 "moved"
if [ -e "$tmp/raced" ] && [ "$(git -C "$R" log -1 --format=%s main)" = "chore: someone else's commit" ]; then
  ok
else
  bad "the commit that landed in the meantime is still the tip" "$(git -C "$R" log --oneline -3 main)"
fi
if [ -z "$(rescue_refs)" ]; then ok; else bad "a refused move leaves no rescue ref" "$(rescue_refs)"; fi

# --- the rescue ref is created, never overwritten ----------------------------
mkrepo; t=$(tip); short=$(git -C "$R" rev-parse --short "$t")
git -C "$R" update-ref "refs/rescue/reword/main/$short" "$t"
json '[{"old": "retries twice", "new": "retries three times"}]'
rw --base base --replace "$tmp/replace.json"
check "an existing rescue ref at the same commit is accepted" 0 "refs/rescue/reword/main/$short"
if [ "$(tip)" != "$t" ] && [ "$(git -C "$R" rev-parse "refs/rescue/reword/main/$short")" = "$t" ]; then ok; else bad "the rewrite lands and the rescue ref still names the old tip" "$(rescue_refs)"; fi

mkrepo; t=$(tip); short=$(git -C "$R" rev-parse --short "$t"); b=$(git -C "$R" rev-parse base)
git -C "$R" update-ref "refs/rescue/reword/main/$short" "$b"
rw --base base --replace "$tmp/replace.json"
check "an existing rescue ref at another commit is refused" 1 "refs/rescue/reword/main/$short"
if [ "$(tip)" = "$t" ] && [ "$(git -C "$R" rev-parse "refs/rescue/reword/main/$short")" = "$b" ]; then ok; else bad "neither the branch nor the existing rescue ref moves" "$(tip) $(rescue_refs)"; fi

# A branch name with a slash keeps it in the rescue ref and the push command.
mkrepo
git -C "$R" checkout -q -b feature/widget-retry
t=$(tip); short=$(git -C "$R" rev-parse --short "$t")
rw --base base --replace "$tmp/replace.json"
check "a branch with a slash is rewritten" 0 "refs/rescue/reword/feature/widget-retry/$short"
check "the push command names the slashed branch" 0 "--force-with-lease=feature/widget-retry:<remote-tip> <remote> HEAD:feature/widget-retry"
if [ "$(git -C "$R" rev-parse "refs/rescue/reword/feature/widget-retry/$short")" = "$t" ] && [ "$(git -C "$R" rev-parse main)" = "$t" ]; then
  ok
else
  bad "the slashed branch's rescue ref names the old tip, and main is untouched" "$(rescue_refs)"
fi

# --- messages the helper cannot represent ----------------------------------
# A commit with an encoding header would be rewritten as mis-declared UTF-8,
# and git commit-tree re-encodes a message that is not valid UTF-8, so either
# one, among the commits that would be recreated, is refused. The refusal
# names the commit, and printing its bytes must not raise.
mkrepo
printf 'fix: legacy encoding\n\nCaf\xe9 menu retries.\n' > "$tmp/latin1"
echo x >> "$R/l.txt"; git -C "$R" add l.txt
GIT_AUTHOR_DATE="2026-01-05 10:00:00 +0000" git -C "$R" -c i18n.commitEncoding=ISO-8859-1 commit -q -F "$tmp/latin1"
t=$(tip)
rw --base base --drop-lines '^Co-Authored-By:'
check "a commit with an encoding header is refused" 1 "encoding"
unchanged "encoding header" "$t"

mkrepo
tree=$(git -C "$R" rev-parse 'HEAD^{tree}')
# commit-tree would re-encode the byte, so the object is written directly.
raw=$(printf 'tree %s\nparent %s\nauthor Ada Example <ada@example.com> 1767607200 +0000\ncommitter Cy Example <cy@example.com> 1767607200 +0000\n\nfix: raw \xff byte\n\nThe widget waits.\n' \
  "$tree" "$(git -C "$R" rev-parse HEAD)" | git -C "$R" hash-object -t commit -w --stdin)
git -C "$R" update-ref refs/heads/main "$raw"
t=$(tip)
json '[{"old": "widget waits", "new": "widget waits longer"}]'
# A strict UTF-8 stdout is what a UTF-8 terminal gives Python; the C locale
# the tests may run under would hide the error.
export PYTHONIOENCODING=utf-8:strict
rw --base base --replace "$tmp/replace.json" --dry-run
check "a message that is not UTF-8 is refused, in a dry run too" 1 "not valid UTF-8"
if grep -q Traceback <<<"$out"; then bad "printing undecodable bytes must not raise" "$out"; else ok; fi
rw --base base --replace "$tmp/replace.json"
check "a message that is not UTF-8 is refused" 1 "not valid UTF-8"
if grep -q Traceback <<<"$out"; then bad "the refusal must not raise on undecodable bytes" "$out"; else ok; fi
unchanged "message not UTF-8" "$t"
unset PYTHONIOENCODING

# --- signatures ---------------------------------------------------------------
# A stub signing program stands in for gpg: it reads the payload, reports the
# status line git waits for, and prints a fixed signature block.
cat > "$tmp/fake-gpg" <<'GPG'
#!/usr/bin/env bash
cat > /dev/null
echo "[GNUPG:] SIG_CREATED D 1 8 00 1767607200 0000000000000000000000000000000000000000" >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nc3R1Yg==\n-----END PGP SIGNATURE-----\n'
GPG
chmod +x "$tmp/fake-gpg"

mkrepo
git -C "$R" config gpg.program "$tmp/fake-gpg"
git -C "$R" config user.signingkey example-key
git -C "$R" config commit.gpgsign true
json '[{"old": "retries twice", "new": "retries three times"}]'
rw --base base --replace "$tmp/replace.json"
check "with commit.gpgsign set the rewrite succeeds" 0
if git -C "$R" cat-file commit "$(tip)" | grep -q '^gpgsig '; then ok; else bad "rewritten commits are signed when commit.gpgsign is set" "$(git -C "$R" cat-file commit "$(tip)")"; fi
if grep -q "carried a signature" <<<"$out"; then bad "no signature note when commits are re-signed" "$out"; else ok; fi

# Signed originals, signing now off: the signatures are dropped, and it says so.
git -C "$R" config commit.gpgsign false
rw --base base --drop-lines '^Co-Authored-By:'
check "signed originals with signing off are rewritten" 0 "2 commit(s) that would be recreated carried a signature"
if git -C "$R" cat-file commit "$(tip)" | grep -q '^gpgsig '; then bad "with signing off the new commits are unsigned"; else ok; fi

mkrepo
rw --base base --drop-lines '^Co-Authored-By:'
if grep -q "carried a signature" <<<"$out"; then bad "no signature note when nothing was signed" "$out"; else ok; fi

# --- --remote-tip names the lease ------------------------------------------
# The remote holds an ancestor of the local tip when the round's commits were
# never pushed; the lease must name what the remote holds, as the caller says.
mkrepo; read -r c1 c2 c3 < <(shas | tr '\n' ' ')
json '[{"old": "retries twice", "new": "retries three times"}]'
rw --base base --replace "$tmp/replace.json" --remote-tip "$c2"
check "with --remote-tip the push command names that sha" 0 "git push --force-with-lease=main:$c2 <remote> HEAD:main"
if grep -qF "<remote-tip>" <<<"$out"; then bad "no placeholder is printed when --remote-tip is given" "$out"; else ok; fi

mkrepo; t=$(tip)
rw --base base --replace "$tmp/replace.json" --remote-tip abc123
check "a short --remote-tip is a usage error" 3 "full 40-character"
unchanged "short remote tip" "$t"
rw --base base --replace "$tmp/replace.json" --remote-tip 1234567890abcdef1234567890abcdef12345678
check "a --remote-tip that is not in the repository is a usage error" 3 "not a commit"
unchanged "unknown remote tip" "$t"

# --- the attribution sweep exactly as SKILL.md writes it ---------------------
# Step 2's detection loop and Step 3's helper command are read out of the
# skill text and run as written, so the test fails when the text drifts. Both
# must agree: whatever Step 3 removes, Step 2 then finds nothing, and a line
# that only mentions the rule in a sentence is neither detected nor removed.
SKILL="$SCRIPT_DIR/SKILL.md"
section() {
  python3 - "$SKILL" "$1" "$2" <<'EXTRACT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
start, end = text.index(sys.argv[2]), text.index(sys.argv[3])
blocks = re.findall(r"```bash\n(.*?)```", text[start:end], re.S)
print([b for b in blocks if "reword-commits.py" in b or "ATTRIBUTED" in b][-1], end="")
EXTRACT
}
detect=$(section "### Step 2" "### Step 3")
strip=$(section "### Step 3" "### Step 4")
detect=${detect//<BASE_REMOTE>\/<BASE_BRANCH>/base}
strip=${strip//<BASE_REMOTE>\/<BASE_BRANCH>/base}
if grep -q "ATTRIBUTED" <<<"$detect" && grep -q -- "--drop-lines" <<<"$strip"; then ok; else bad "Step 2 and Step 3 blocks are found in SKILL.md" "$detect
---
$strip"; fi
# The patterns are the same text in both steps.
pat2=$(grep -oE -- "-e '[^']*'" <<<"$detect" | sed "s/^-e //" | sort)
pat3=$(grep -oE -- "--drop-lines '[^']*'" <<<"$strip" | sed "s/^--drop-lines //" | sort)
if [ -n "$pat2" ] && [ "$pat2" = "$pat3" ]; then ok; else bad "Step 2 and Step 3 use the same patterns" "step 2:
$pat2
step 3:
$pat3"; fi

mkrepo
commit "$R" 05 f.txt "feat: robot footer

Body.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
"
commit "$R" 06 g.txt "fix: lower-case trailer

Body.

co-authored-by: claude <noreply@anthropic.com>
"
commit "$R" 07 h.txt "chore: listed trailer

Changes:
- one thing
  - Co-Authored-By: Claude <noreply@anthropic.com>

Generated with Claude Code
"
commit "$R" 08 i.txt "docs: describe the sweep

Strip Co-Authored-By: Claude trailers, and the Generated with Claude Code footer.
"
prose=$(tip)
before_detect=$(cd "$R" && bash -c "$detect")
if [ "$(grep -c ATTRIBUTED <<<"$before_detect")" = "3" ] && ! grep -q "docs: describe the sweep" <<<"$before_detect"; then
  ok
else
  bad "Step 2 detects the three attributed commits and not the prose one" "$before_detect"
fi
out=$(cd "$R" && CLAUDE_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)" REMOTE_TIP=$(git rev-parse HEAD) bash -c "$strip" 2>&1); got=$?
check "Step 3's command, as written, rewrites the branch" 0 "rewrote 3 message(s)"
after_detect=$(cd "$R" && bash -c "$detect")
if [ -z "$after_detect" ]; then ok; else bad "Step 2 finds nothing after Step 3" "$after_detect"; fi
if [ "$(msg "$(tip)")" = "$(git -C "$R" cat-file commit "$prose" | sed '1,/^$/d')" ]; then ok; else bad "the prose commit's message is unchanged" "$(msg "$(tip)")"; fi
listed=$(git -C "$R" log -1 --format=%B "$(git -C "$R" rev-parse HEAD~1)")
if [ "$listed" = $'chore: listed trailer\n\nChanges:\n- one thing' ]; then ok; else bad "the indented trailer and the plain footer are removed" "$listed"; fi

# --- usage --------------------------------------------------------------------
mkrepo
rw --replace "$tmp/replace.json"
check "a missing --base is a usage error" 3
rw --base base --replace "$tmp/replace.json" --drop-lines x
check "--replace with --drop-lines is a usage error" 3
rw --base no-such-ref --drop-lines x
check "an unknown base is exit 3" 3 "no-such-ref"
rw --base base --drop-lines '('
check "an invalid regular expression is a usage error" 3
rw --help
check "--help lists the exit statuses" 0 "Exit statuses"
t=$(tip)
json '[{"old": "retries twice", "new": "retries three times", "subject-prefix": "fix:"}]'
rw --base base --replace "$tmp/replace.json"
check "an unknown key in a --replace entry is a usage error" 3 "subject-prefix"
unchanged "unknown key" "$t"
mkdir -p "$tmp/no-git"
# The interpreter's own path, since a version-manager shim needs a shell on PATH.
py=$(python3 -c 'import sys; print(sys.executable)')
out=$(cd "$R" && PATH="$tmp/no-git" "$py" "$RW" --base base --drop-lines x 2>&1); got=$?
check "a git that cannot be started is exit 3" 3 "cannot run git"
if grep -q Traceback <<<"$out"; then bad "a missing git gives a message, not a traceback" "$out"; else ok; fi

# --- a root commit in the range ----------------------------------------------
# The range can begin at a root commit (a base on an unrelated history); the
# recreated root must stay parentless.
mkrepo
git -C "$R" checkout -q --orphan fresh
git -C "$R" rm -rq --cached .
commit "$R" 09 root.txt "feat: fresh root

Co-Authored-By: Example Bot <bot@example.com>
"
commit "$R" 10 root.txt "fix: fresh follow-up"
old_root=$(git -C "$R" rev-list --max-parents=0 fresh)
old_root_tree=$(git -C "$R" rev-parse "$old_root^{tree}")
out=$(cd "$R" && python3 "$RW" --base main --drop-lines '^Co-Authored-By:' 2>&1); got=$?
check "a range that starts at a root commit is rewritten" 0 "rewrote 1 message(s)"
new_root=$(git -C "$R" rev-list --max-parents=0 fresh)
if [ "$new_root" != "$old_root" ] && [ "$(git -C "$R" rev-parse "$new_root^{tree}")" = "$old_root_tree" ] \
   && [ "$(git -C "$R" rev-list --count fresh)" = "2" ]; then
  ok
else
  bad "the new root has no parent and keeps its tree" "$(git -C "$R" log --format='%h %p %s' fresh)"
fi

if [ "$fail" -eq 0 ]; then
  printf 'ok: %d reword-commits cases passed\n' "$pass"
  exit 0
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
exit 1
