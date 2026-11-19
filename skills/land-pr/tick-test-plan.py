#!/usr/bin/env python3
"""Tick one test-plan box in a PR description and record its evidence.

Usage:
  tick-test-plan.py <PR> --box "<start of the box's text>" --evidence "<one line>"
                    [--repo <owner>/<repo>] [--under "<text of a heading>"]
                    [--note-only] [--dry-run]
  tick-test-plan.py <PR> --from <file.json> [--repo ...] [--dry-run]
  tick-test-plan.py --file <body.md> --box ... --evidence ...

What it decides: which line of the description is the box being recorded,
and that exactly one line is. A wrong or ambiguous match changes nothing.

A box is a line that starts, after optional indentation, with "- [ ] " or
"- [x] " (any case of x). --box matches a box whose text after the marker
starts with the given text, compared exactly; a box that merely contains the
text later in its line does not match. With --under, only boxes below a
heading whose text contains the given text are candidates, up to the next
heading of the same or a higher level. Lines inside fenced code blocks are
neither boxes nor headings.

Without --note-only the box must be unticked; it is ticked, and the evidence
is added as a nested item two spaces deeper than the box, after the box's
existing nested lines. With --note-only the mark is left as it is and the
evidence is added the same way, for a box that was checked and not met as
written. --from takes a JSON list of objects with "box", "evidence", and
optionally "under" and "note_only"; every entry is resolved against the one
fresh description before anything is written.

The description is read fresh with `gh pr view <PR> --json body` at every run
and written back with `gh pr edit <PR> --body-file` only when it changed.
--file edits a local file in place instead and never calls gh. Everything
outside the edit is preserved byte for byte, including CRLF endings and a
missing final newline.

Exit statuses:
  0  done, or nothing to change under --dry-run
  1  a box could not be resolved (no match, or more than one), or is already
     ticked; nothing was written
  3  a usage error, or a failing gh

Why a script: the inline version of this was retyped in session after session,
and its two quiet failures are ticking the first of two boxes with the same
text, and recording evidence twice on a box that was already ticked. Both
leave a description that looks right to anyone who does not reread it.
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile

# The tests point this at a stub gh; nothing else should set it.
GH = os.environ.get("TICK_TEST_PLAN_GH", "gh")

EXIT_UNRESOLVED = 1
EXIT_USAGE = 3

BOX_RE = re.compile(r"^([ \t]*)- \[([ xX])\] (.*)$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


class Refused(Exception):
    """The request cannot be applied; the message says why."""


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    # argparse exits 2 on a usage error; this script's contract says 3.
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        sys.exit(EXIT_USAGE)


def split_lines(text):
    """Split into (content, ending) pairs, keeping each line's own ending."""
    out = []
    for raw in re.split(r"(?<=\n)", text):
        if raw == "":
            continue
        if raw.endswith("\r\n"):
            out.append((raw[:-2], "\r\n"))
        elif raw.endswith("\n"):
            out.append((raw[:-1], "\n"))
        else:
            out.append((raw, ""))
    return out


def indent_width(s):
    return len(s.expandtabs(4)) - len(s.expandtabs(4).lstrip(" "))


def scan(lines):
    """Return (boxes, headings): boxes as dicts, headings as (index, level, text)."""
    boxes, headings = [], []
    fence = None
    for i, (content, _) in enumerate(lines):
        m = FENCE_RE.match(content)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        h = HEADING_RE.match(content)
        if h:
            headings.append((i, len(h.group(1)), h.group(2) or ""))
            continue
        b = BOX_RE.match(content)
        if b:
            boxes.append({"index": i, "indent": b.group(1), "mark": b.group(2), "text": b.group(3)})
    return boxes, headings


def under(box_index, headings, needle):
    """True when a heading containing needle encloses the line at box_index."""
    for hi, (h_index, level, text) in enumerate(headings):
        if h_index > box_index or needle not in text:
            continue
        closed = any(
            h_index < o_index < box_index and o_level <= level
            for o_index, o_level, _ in headings[hi + 1:]
        )
        if not closed:
            return True
    return False


def last_nested(lines, box):
    """Index of the last line nested under the box (the box itself if none)."""
    width = indent_width(box["indent"])
    last = box["index"]
    for j in range(box["index"] + 1, len(lines)):
        content = lines[j][0]
        if content.strip() == "":
            continue
        if indent_width(content) > width:
            last = j
        else:
            break
    return last


def show(lines, index):
    return f"  {index + 1}: {lines[index][0][:80]}"


def resolve(lines, boxes, headings, entry):
    scope = boxes
    if entry.get("under") is not None:
        scope = [b for b in boxes if under(b["index"], headings, entry["under"])]
    matches = [b for b in scope if b["text"].startswith(entry["box"])]
    where = f" under a heading containing {entry['under']!r}" if entry.get("under") is not None else ""
    if len(matches) == 1:
        box = matches[0]
        if box["mark"] != " " and not entry.get("note_only"):
            raise Refused(
                f"box {entry['box']!r} is already ticked (line {box['index'] + 1}); "
                "pass --note-only to add a note to it\n" + show(lines, box["index"])
            )
        return box
    if not matches:
        listing = "\n".join(show(lines, b["index"]) for b in scope) or "  (no boxes)"
        raise Refused(f"no box{where} starts with {entry['box']!r}; candidates considered:\n{listing}")
    listing = "\n".join(show(lines, b["index"]) for b in matches)
    raise Refused(
        f"{entry['box']!r}{where} is ambiguous: {len(matches)} boxes start with it "
        f"(narrow it with --under or a longer --box):\n{listing}"
    )


def check_entry(entry, n):
    label = f"entry {n}: " if n is not None else ""
    if not isinstance(entry, dict):
        raise UsageError(f"{label}each --from entry must be an object")
    for key in ("box", "evidence"):
        if not isinstance(entry.get(key), str):
            raise UsageError(f"{label}{key!r} is required and must be a string")
    if entry["box"] == "":
        raise UsageError(f"{label}'box' must not be empty")
    ev = entry["evidence"]
    if "\n" in ev or "\r" in ev:
        raise UsageError(f"{label}evidence must be one line")
    if ev.strip() == "":
        raise UsageError(f"{label}evidence must not be empty")
    if entry.get("under") is not None and not isinstance(entry["under"], str):
        raise UsageError(f"{label}'under' must be a string")
    if not isinstance(entry.get("note_only", False), bool):
        raise UsageError(f"{label}'note_only' must be true or false")


def apply(text, entries):
    lines = split_lines(text)
    boxes, headings = scan(lines)
    resolved = [resolve(lines, boxes, headings, e) for e in entries]

    ticking = {}
    for e, box in zip(entries, resolved):
        if not e.get("note_only"):
            if box["index"] in ticking:
                raise Refused(f"two entries tick the same box (line {box['index'] + 1})")
            ticking[box["index"]] = e

    default_eol = next((eol for _, eol in lines if eol), "\n")
    # Inserted lines keyed by the line they follow. A box nested inside another
    # target box can share that box's insertion point; the deeper box's lines
    # go first so each note stays next to its own box.
    # The sort is stable, so entries for one box keep their given order.
    inserts = {}
    for e, box in sorted(zip(entries, resolved), key=lambda p: -p[1]["index"]):
        at = last_nested(lines, box)
        inserts.setdefault(at, []).append(box["indent"] + "  - " + e["evidence"])

    out = []
    for i, (content, eol) in enumerate(lines):
        if i in ticking:
            b = BOX_RE.match(content)
            content = f"{b.group(1)}- [x] {b.group(3)}"
        added = inserts.get(i, [])
        if not added:
            out.append(content + eol)
            continue
        # After a last line with no ending, the new lines need one between
        # them, and the description still ends without one.
        use = eol or default_eol
        out.append(content + use)
        for k, new in enumerate(added):
            out.append(new + (eol if k == len(added) - 1 else use))
    return "".join(out)


def summary(text):
    boxes, _ = scan(split_lines(text))
    ticked = [b for b in boxes if b["mark"] != " "]
    left = [b for b in boxes if b["mark"] == " "]
    lines = [f"{len(ticked)} ticked, {len(left)} unticked"]
    lines += [f"  unticked: {b['text']}" for b in left]
    return "\n".join(lines)


def diff(old, new, name):
    a = [c + e for c, e in split_lines(old)]
    b = [c + e for c, e in split_lines(new)]
    out = []
    for line in difflib.unified_diff(a, b, f"a/{name}", f"b/{name}"):
        if line.endswith("\n"):
            out.append(line)
        else:
            out.append(line + "\n\\ No newline at end of file\n")
    return "".join(out)


def gh(args):
    try:
        p = subprocess.run([GH] + args, capture_output=True, text=True)
    except OSError as exc:
        raise UsageError(f"cannot run {GH}: {exc}")
    if p.returncode != 0:
        raise UsageError(f"gh {' '.join(args[:2])} failed (exit {p.returncode}): {p.stderr.strip()}")
    return p.stdout


def main(argv):
    parser = Parser(
        prog="tick-test-plan.py",
        description="Tick one test-plan box in a PR description and record its evidence.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit statuses:\n"
            "  0  done, or nothing to change under --dry-run\n"
            "  1  a box could not be resolved (no match, or more than one), or is\n"
            "     already ticked; nothing was written\n"
            "  3  a usage error, or a failing gh"
        ),
    )
    parser.add_argument("pr", nargs="?", help="PR number (omit with --file)")
    parser.add_argument("--repo", help="<owner>/<repo>, passed to gh")
    parser.add_argument("--file", help="edit this local description instead of a PR")
    parser.add_argument("--box", help="the start of the box's text, compared exactly")
    parser.add_argument("--evidence", help="one line recorded beneath the box")
    parser.add_argument("--under", help="only boxes below a heading containing this text")
    parser.add_argument("--note-only", action="store_true", help="add the evidence and leave the mark")
    parser.add_argument("--from", dest="from_file", help="JSON list of {box, evidence, under?, note_only?}")
    parser.add_argument("--dry-run", action="store_true", help="print a diff and write nothing")
    args = parser.parse_args(argv)

    if (args.pr is None) == (args.file is None):
        parser.error("give exactly one of a PR number or --file")
    if args.file is not None and args.repo is not None:
        parser.error("--repo applies to a PR, not to --file")
    if args.from_file is not None:
        if args.box is not None or args.evidence is not None or args.under is not None or args.note_only:
            parser.error("--from replaces --box, --evidence, --under, and --note-only")
        try:
            with open(args.from_file, encoding="utf-8") as fh:
                entries = json.load(fh)
        except (OSError, ValueError) as exc:
            parser.error(f"cannot read --from file: {exc}")
        if not isinstance(entries, list) or not entries:
            parser.error("--from must hold a non-empty JSON list")
        numbered = list(enumerate(entries, 1))
    else:
        if args.box is None or args.evidence is None:
            parser.error("--box and --evidence are required (or use --from)")
        entries = [{"box": args.box, "evidence": args.evidence, "under": args.under, "note_only": args.note_only}]
        numbered = [(None, entries[0])]

    try:
        for n, e in numbered:
            check_entry(e, n)

        repo = ["--repo", args.repo] if args.repo else []
        if args.file is not None:
            try:
                with open(args.file, encoding="utf-8", newline="") as fh:
                    old = fh.read()
            except OSError as exc:
                raise UsageError(f"cannot read {args.file}: {exc}")
            name = os.path.basename(args.file)
        else:
            raw = gh(["pr", "view", args.pr, "--json", "body"] + repo)
            try:
                old = json.loads(raw)["body"]
            except (ValueError, KeyError, TypeError):
                raise UsageError(f"gh pr view returned no body: {raw[:200]!r}")
            if not isinstance(old, str):
                raise UsageError("gh pr view returned a body that is not a string")
            name = f"PR-{args.pr}"

        new = apply(old, entries)

        if args.dry_run:
            sys.stdout.write(diff(old, new, name) or "nothing to change\n")
            return 0
        if new == old:
            print("nothing to change")
            return 0

        if args.file is not None:
            with open(args.file, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)
        else:
            fd, path = tempfile.mkstemp(prefix="tick-test-plan-", suffix=".md")
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
                    fh.write(new)
                gh(["pr", "edit", args.pr, "--body-file", path] + repo)
            finally:
                os.unlink(path)
        print(summary(new))
        return 0
    except Refused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        print("nothing was written", file=sys.stderr)
        return EXIT_UNRESOLVED
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
