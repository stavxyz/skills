#!/usr/bin/env python3
"""Change commit messages on a branch without touching what the commits contain.

Usage:
  reword-commits.py --base <ref> --replace <file.json> [--remote-tip <sha>] [--dry-run]
  reword-commits.py --base <ref> --drop-lines '<regex>' [--drop-lines '<regex>' ...]
                    [--ignore-case] [--remote-tip <sha>] [--dry-run]

What it decides: that a message edit lands on exactly the commits it was meant
for, and that the content does not change. Every rewritten commit keeps its
tree, author, and author date. Its committer becomes whoever runs the tool,
with the current date, as after a rebase, and it is signed only when
commit.gpgsign is set; when signing is off and a commit that would be
recreated carried a signature, the tool says so in one line before rewriting.

The range is <base>..HEAD on the current branch, oldest first, and must be
linear: a detached HEAD, an empty range, or a merge commit in it is refused.

--replace takes a JSON list of objects with "old" and "new", and optionally
"subject_prefix" and "every". An entry applies to the commits whose subject
starts with subject_prefix (all commits when it is absent) and whose message
contains old. It must match exactly one commit, and old must occur exactly
once in that message; with "every": true it replaces every occurrence in every
matching commit and must match at least one. Entries apply in the order given,
each to the messages as the earlier entries left them.

--drop-lines removes every line of every message in the range that the
regular expression matches (re.search), then trims trailing blank lines from
that message. A pattern that matches a subject line is refused. --ignore-case
matches the patterns in any letter case, as `grep -i` does, so one set of
patterns can serve a grep that detects lines and this tool that removes them.

The rewrite uses git commit-tree, not a rebase, so the index and working tree
are never touched; that is safe because the tip's tree does not change, and
uncommitted changes survive. Commits before the first changed one keep their
shas. One `git update-ref --stdin` transaction creates the rescue ref
refs/rescue/reword/<branch>/<short sha> at the old tip and moves the branch,
naming the old tip as its expected value: both land or neither does, so a
branch that moved in the meantime is left alone and no rescue ref is left
behind. The rescue ref is created, never overwritten; one of that name that
already names the old tip is accepted, and one that names another commit is
refused. The tool never pushes; it prints the push command to run.

The push lease names --remote-tip, the sha the caller knows the remote branch
to hold (for a pull request, the head that was last reviewed). Without it the
command carries a placeholder in that position. The tool never reads a
remote-tracking ref to fill it in: a fetch can have moved that ref to a commit
nobody reviewed, which is the commit a named lease exists to protect, and the
local old tip is wrong whenever some of the branch was never pushed.

A commit that would be recreated and carries an encoding header, or whose
message is not valid UTF-8, is refused: git commit-tree would write it back
as UTF-8 and change its bytes.

Exit statuses:
  0  rewritten, or nothing to do
  1  refused: detached HEAD, empty range, merge commit in the range, a
     recreated commit with an encoding header or a message that is not
     UTF-8, an edit that matches no commit, several commits, or several
     places in one message, a pattern that matches a subject, a message that
     would become empty, or a branch that moved during the rewrite
  3  a usage error, or a failing git

Why a script: sessions kept driving `git rebase -i` through editor hooks or
running `git filter-branch` for this. Both can land an edit on the wrong
commit without saying so, and both rewrite through the working tree, which
fails or carries along whatever is uncommitted.
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys

EXIT_REFUSED = 1
EXIT_USAGE = 3


class Refused(Exception):
    pass


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    # argparse exits 2 on a usage error; this script's contract says 3.
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        sys.exit(EXIT_USAGE)


def git(args, stdin=None, env=None, check=True):
    try:
        p = subprocess.run(["git"] + args, input=stdin, capture_output=True, env=env)
    except OSError as exc:
        raise UsageError(f"cannot run git: {exc}")
    if check and p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip()
        raise UsageError(f"git {' '.join(args[:2])} failed (exit {p.returncode}): {err}")
    return p


def out(args):
    return git(args).stdout.decode("utf-8", "surrogateescape").strip()


def read_commit(sha):
    raw = git(["cat-file", "commit", sha]).stdout.decode("utf-8", "surrogateescape")
    header, _, message = raw.partition("\n\n")
    info = {"sha": sha, "parents": [], "message": message, "encoding": None, "signed": False}
    try:
        message.encode("utf-8")
        info["utf8"] = True
    except UnicodeEncodeError:
        info["utf8"] = False
    for line in header.split("\n"):
        if line.startswith("encoding "):
            info["encoding"] = line[9:]
        elif line.startswith(("gpgsig ", "gpgsig-sha256 ")):
            info["signed"] = True
        elif line.startswith("tree "):
            info["tree"] = line[5:]
        elif line.startswith("parent "):
            info["parents"].append(line[7:])
        elif line.startswith("author "):
            m = re.match(r"^author (.*) <(.*)> (\d+ [+-]\d{4})$", line)
            if not m:
                raise UsageError(f"cannot parse the author of {sha}: {line!r}")
            info["author"] = m.groups()
    return info


def subject(message):
    return message.split("\n", 1)[0]


def short(sha):
    return out(["rev-parse", "--short", sha])


def describe(c):
    return f"  {short(c['sha'])} {subject(c['message'])}"


def stale_sha_mentions(commits, messages, first):
    """Messages in the range that cite a commit this rewrite replaces.

    Every commit from the first changed one onward gets a new sha, so a later
    message that names one of them by sha ("fixes the test added in 1a2b3c4")
    is left pointing at a commit that is no longer on the branch. Returns
    (index of the citing commit, the cited text, index of the cited commit).
    """
    replaced = [(i, c["sha"]) for i, c in enumerate(commits) if i >= first]
    found = []
    for i, m in enumerate(messages):
        for word in set(re.findall(r"\b[0-9a-fA-F]{7,40}\b", m)):
            for j, sha in replaced:
                if sha.startswith(word.lower()):
                    found.append((i, word, j))
    return sorted(found)


def print_stale_mentions(commits, messages, first, new_shas=None):
    mentions = stale_sha_mentions(commits, messages, first)
    if not mentions:
        return
    print(
        f"note: {len(mentions)} mention(s) of a sha this rewrite replaces. Fix each with --replace "
        "in a second pass, or the message will cite a commit that is not on the branch:"
    )
    for i, word, j in mentions:
        now = f" (now {short(new_shas[j])})" if new_shas else ""
        where = short(new_shas[i]) if new_shas else short(commits[i]["sha"])
        print(f"  {where} \"{subject(messages[i])}\" cites {word}{now}")


def apply_replace(commits, entries, messages):
    for n, e in enumerate(entries, 1):
        prefix = e.get("subject_prefix", "")
        old, new = e["old"], e["new"]
        hits = [
            i for i, c in enumerate(commits)
            if subject(messages[i]).startswith(prefix) and old in messages[i]
        ]
        label = f"entry {n} ({old!r})"
        if not hits:
            raise Refused(f"{label} matches no commit in the range")
        if e.get("every"):
            for i in hits:
                messages[i] = messages[i].replace(old, new)
            continue
        if len(hits) > 1:
            listing = "\n".join(describe(commits[i]) for i in hits)
            raise Refused(f"{label} matches {len(hits)} commits; narrow it with subject_prefix:\n{listing}")
        i = hits[0]
        count = messages[i].count(old)
        if count != 1:
            raise Refused(
                f"{label} occurs {count} times in one message; give a longer old, "
                f"or set \"every\": true:\n{describe(commits[i])}"
            )
        messages[i] = messages[i].replace(old, new)


def apply_drop(commits, patterns, messages):
    for i, c in enumerate(commits):
        lines = messages[i].split("\n")
        for p in patterns:
            if p.search(lines[0]):
                raise Refused(f"--drop-lines {p.pattern!r} matches a subject line:\n{describe(c)}")
        kept = [lines[0]] + [ln for ln in lines[1:] if not any(p.search(ln) for p in patterns)]
        if kept == lines:
            continue
        while kept and kept[-1].strip() == "":
            kept.pop()
        messages[i] = "\n".join(kept) + "\n"


def main(argv):
    # Messages are decoded with surrogateescape; printing one that is not
    # UTF-8 must not raise on a strict terminal.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="replace")
    parser = Parser(
        prog="reword-commits.py",
        description="Change commit messages on a branch without touching what the commits contain.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit statuses:\n"
            "  0  rewritten, or nothing to do\n"
            "  1  refused (detached HEAD, empty range, merge in the range, an encoding\n"
            "     header or a message that is not UTF-8, an edit that does not match\n"
            "     exactly as required, a pattern matching a subject, an empty message,\n"
            "     or a branch that moved during the rewrite)\n"
            "  3  a usage error, or a failing git"
        ),
    )
    parser.add_argument("--base", required=True, help="rewrite <base>..HEAD")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--replace", help="JSON list of {old, new, subject_prefix?, every?}")
    mode.add_argument("--drop-lines", action="append", help="remove lines matching this regex (repeatable)")
    parser.add_argument("--ignore-case", "-i", action="store_true", help="match --drop-lines patterns in any letter case")
    parser.add_argument("--remote-tip", help="full sha the remote branch holds; the push lease names it")
    parser.add_argument("--dry-run", action="store_true", help="print each message diff and change nothing")
    args = parser.parse_args(argv)

    entries = patterns = None
    if args.ignore_case and args.drop_lines is None:
        parser.error("--ignore-case applies to --drop-lines")
    if args.replace is not None:
        try:
            with open(args.replace, encoding="utf-8") as fh:
                entries = json.load(fh)
        except (OSError, ValueError) as exc:
            parser.error(f"cannot read --replace file: {exc}")
        if not isinstance(entries, list) or not entries:
            parser.error("--replace must hold a non-empty JSON list")
        for n, e in enumerate(entries, 1):
            if not isinstance(e, dict) or not isinstance(e.get("old"), str) or not isinstance(e.get("new"), str):
                parser.error(f"entry {n}: 'old' and 'new' are required strings")
            # A misspelt key such as "subject-prefix" would otherwise widen the
            # edit to every commit without a word.
            unknown = sorted(set(e) - {"old", "new", "subject_prefix", "every"})
            if unknown:
                parser.error(f"entry {n}: unknown key(s) {', '.join(unknown)}; allowed: old, new, subject_prefix, every")
            if e["old"] == "":
                parser.error(f"entry {n}: 'old' must not be empty")
            if not isinstance(e.get("subject_prefix", ""), str):
                parser.error(f"entry {n}: 'subject_prefix' must be a string")
            if not isinstance(e.get("every", False), bool):
                parser.error(f"entry {n}: 'every' must be true or false")
    else:
        try:
            flags = re.IGNORECASE if args.ignore_case else 0
            patterns = [re.compile(p, flags) for p in args.drop_lines]
        except re.error as exc:
            parser.error(f"invalid --drop-lines pattern: {exc}")

    try:
        head_ref = out(["rev-parse", "--symbolic-full-name", "HEAD"])
        if not head_ref.startswith("refs/heads/"):
            raise Refused("HEAD is detached; check out the branch to reword")
        branch = head_ref[len("refs/heads/"):]
        p = git(["rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}"], check=False)
        if p.returncode != 0:
            raise UsageError(f"--base {args.base} does not name a commit")
        old_tip = out(["rev-parse", "--verify", head_ref])
        if args.remote_tip is not None:
            # A short sha could resolve to a different commit later; the lease
            # must name exactly one.
            if not re.fullmatch(r"[0-9a-f]{40}", args.remote_tip):
                raise UsageError(f"--remote-tip must be a full 40-character sha, got: {args.remote_tip}")
            if git(["cat-file", "-e", f"{args.remote_tip}^{{commit}}"], check=False).returncode != 0:
                raise UsageError(f"--remote-tip {args.remote_tip} is not a commit in this repository")

        listing = out(["rev-list", "--reverse", f"{args.base}..{old_tip}"])
        shas = listing.split() if listing else []
        if not shas:
            raise Refused(f"the range {args.base}..HEAD is empty")
        commits = [read_commit(s) for s in shas]
        merges = [c for c in commits if len(c["parents"]) > 1]
        if merges:
            raise Refused(
                "the range holds a merge commit; only a linear range is supported:\n"
                + "\n".join(describe(c) for c in merges)
            )

        messages = [c["message"] for c in commits]
        if entries is not None:
            apply_replace(commits, entries, messages)
        else:
            apply_drop(commits, patterns, messages)

        empty = [commits[i] for i, m in enumerate(messages) if m.strip() == ""]
        if empty:
            raise Refused("a message would become empty:\n" + "\n".join(describe(c) for c in empty))

        changed = [i for i, c in enumerate(commits) if messages[i] != c["message"]]
        # git commit-tree writes a message as UTF-8 with no encoding header and
        # re-encodes bytes that are not UTF-8, so these commits cannot be
        # recreated with their messages intact.
        unrepresentable = []
        if changed:
            for c in commits[changed[0]:]:
                if c["encoding"]:
                    unrepresentable.append(f"{describe(c)} (carries an encoding header: {c['encoding']})")
                elif not c["utf8"]:
                    unrepresentable.append(f"{describe(c)} (its message is not valid UTF-8)")
        if unrepresentable:
            raise Refused(
                "these commits would be recreated, and their messages cannot be kept exactly:\n"
                + "\n".join(unrepresentable)
            )

        if not changed:
            print("nothing to change: no commit message in the range would differ")
            return 0

        if args.dry_run:
            for i in changed:
                c = commits[i]
                sys.stdout.writelines(difflib.unified_diff(
                    c["message"].splitlines(keepends=True),
                    messages[i].splitlines(keepends=True),
                    f"a/{short(c['sha'])}", f"b/{short(c['sha'])}",
                ))
                if not messages[i].endswith("\n"):
                    sys.stdout.write("\n")
            print_stale_mentions(commits, messages, changed[0])
            print(f"dry run: {len(changed)} commit message(s) would change; nothing was written")
            return 0

        rescue = f"refs/rescue/reword/{branch}/{short(old_tip)}"
        existing = git(["rev-parse", "--verify", "--quiet", rescue], check=False).stdout.decode().strip()
        if existing and existing != old_tip:
            raise Refused(f"{rescue} already exists and names {existing}, not the old tip {old_tip}; it is not overwritten")

        sign = out(["config", "--type=bool", "--default=false", "commit.gpgsign"]) == "true"
        first = changed[0]
        signed = sum(1 for c in commits[first:] if c["signed"])
        if signed and not sign:
            print(
                f"note: {signed} commit(s) that would be recreated carried a signature; "
                "commit.gpgsign is off, so the rewritten commits are unsigned"
            )
        new_shas = [c["sha"] for c in commits[:first]]
        parent = commits[first]["parents"][0] if commits[first]["parents"] else None
        for i in range(first, len(commits)):
            c = commits[i]
            name, email, date = c["author"]
            env = dict(os.environ, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email, GIT_AUTHOR_DATE=date)
            cmd = ["commit-tree", c["tree"]]
            if parent:
                cmd += ["-p", parent]
            if sign:
                cmd.append("-S")
            cmd += ["-F", "-"]
            parent = git(cmd, stdin=messages[i].encode("utf-8", "surrogateescape"), env=env).stdout.decode().strip()
            new_shas.append(parent)

        for c, new in zip(commits, new_shas):
            n = read_commit(new)
            if n["tree"] != c["tree"] or n["author"] != c["author"]:
                raise UsageError(
                    f"verification failed: {short(new)} does not keep the tree and author of "
                    f"{short(c['sha'])}; the branch was not moved"
                )
        new_tip = new_shas[-1]

        # verify, not create, when the rescue ref already names the old tip,
        # since create fails on any existing ref.
        rescue_op = f"verify {rescue} {old_tip}" if existing else f"create {rescue} {old_tip}"
        transaction = f"{rescue_op}\nupdate {head_ref} {new_tip} {old_tip}\n"
        p = git(["update-ref", "-m", "reword-commits", "--stdin"], stdin=transaction.encode(), check=False)
        if p.returncode != 0:
            now = git(["rev-parse", "--verify", "--quiet", head_ref], check=False).stdout.decode().strip()
            if now != old_tip:
                raise Refused(
                    f"{branch} moved during the rewrite (now {now or 'missing'}, was {old_tip}); "
                    "nothing was changed: the branch was not overwritten and no rescue ref was written. "
                    "Run the tool again on the new tip."
                )
            err = p.stderr.decode("utf-8", "replace").strip()
            raise UsageError(f"git update-ref failed (exit {p.returncode}), nothing was changed: {err}")
        print(f"rescue ref: {rescue} -> {old_tip}")

        print(f"rewrote {len(changed)} message(s) on {branch}; every tree, author, and author date verified unchanged")
        for c, new, m in zip(commits, new_shas, messages):
            mark = "*" if m != c["message"] else " "
            print(f"  {mark} {short(c['sha'])} -> {short(new)}  {subject(m)}")
        print_stale_mentions(commits, messages, first, new_shas)
        print("push with:")
        lease = args.remote_tip or "<remote-tip>"
        print(f"  git push --force-with-lease={branch}:{lease} <remote> HEAD:{branch}")
        if args.remote_tip is None:
            print(
                "  <remote-tip> is the sha the remote branch held before the rewrite (for a pull "
                "request, the head you last reviewed); pass it as --remote-tip to have it filled in"
            )
        return 0
    except Refused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return EXIT_REFUSED
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
