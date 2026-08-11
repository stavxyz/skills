#!/usr/bin/env python3
"""Verify `path.py:NN` citations in one spec or plan, as validate findings.

Specs and plans cite source locations as `path/to/file.py:NN`. Nothing reads
those numbers back, so nothing notices when they go wrong. Measured on one
repository in one evening: nine wrong citations across three documents. Only
three were caused by that day's merges; the rest had rotted quietly. Two were
load-bearing -- one was the cited evidence for a premise a whole design
section rested on, and one sat inside a mechanical "update all six call sites"
instruction, which is the kind of wrong pointer that gets FOLLOWED.

One of the nine was never right at all: authored wrong, not drifted.

**A range check cannot catch this class.** That citation was inside the file
and still wrong -- the line existed and said something else. So a citation may
declare what it expects to find:

    `driver.py:73` (`state_mod.load`)

Line number for precision, because prose often points at a block rather than a
symbol. Anchor for verifiability. When the anchor is present we assert it is
UNIQUE in the file and sits on a cited line; on failure we report the line it
is really on, so the fix is mechanical rather than an investigation.

Uniqueness is the property that makes an anchor evidence, and it is measured
rather than approximated by a minimum length. A length floor gets this wrong in
both directions: it rejects a two-character anchor that happens to be unique
(which verifies fine) and accepts `return None`, which appears everywhere and
identifies nothing -- so once the cited code moves, a different `return None`
sits at the cited line and the citation still passes.

An anchor must sit on the citation's own line. Allowing it to wrap would catch
the reflowed case, but would equally bind an ordinary parenthetical that merely
follows an unanchored citation -- failing correct text for something it never
opted into. Between the two errors, the false negative is the safe one: it is
visible in the coverage tally, where a false failure just teaches people to
stop reading the output.

A citation with no anchor is `unverifiable`, not a finding. That is what makes
this adoptable: anchors arrive as documents are touched, with no mass rewrite,
and the check still catches what it can see without one -- a path that does not
resolve, an ambiguous bare filename, a line past the end of the file, and a
reversed range that names no lines at all.

One verdict is neither: a citation into a submodule with no contents checked
out -- what a plain `git clone` leaves behind -- is `unverifiable` and says so,
because the citation may well be correct and nothing here can tell. Reporting
it as a missing file would advise deleting a correct citation.

Paths resolve against `git ls-files`, not a filesystem walk, so what counts as
source is the repository's own `.gitignore` rather than a denylist here that
would always be missing an entry.

Output is validate's own finding format, so `validate` parses these with the
same code that parses its two reviewers. Only ONE verdict yields a correction
that is a drop-in replacement -- the anchor-moved one, whose correction is
itself a citation. Every other correction is an instruction to a human and is
prefixed `[manual] `, because validate auto-applies corrections as edits and
applying prose verbatim would replace a citation in the user's spec with an
English sentence. The marker lives in the output rather than in a list of
exceptions in the prompt: a list goes stale the first time a verdict changes,
and did.

Findings go to stdout; the exit code is 0 unless the run itself failed,
because findings are data for the caller to triage, not a gate.

A path containing a space is not recognised as a citation at all (the path
character class stops at the space). That produces no false finding, but it is
an invisible gap rather than a reported one -- the tally simply will not count
it.

Usage:
    check-citations.py <document.md> [--repo-root DIR] [--strict]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

# `path.ext:12`, `:12-34`, `:12,34`, each optionally followed by an anchor in
# its own backticks. Bare `:12-34` continuations bind to the nearest preceding
# named file -- a real form in these documents, and one a naive sweep misses,
# undercounting by more than half.
#
# `[ \t]*`, NOT `\s*`: the anchor must sit on the citation's own line. Letting
# it span a newline does catch the citation whose anchor wrapped in reflowed
# prose -- but it also binds an ordinary parenthetical that merely follows a
# citation, so a CORRECT unanchored citation fails demanding text it never
# opted into:
#
#     The three phases are `SKILL.md:1`
#     (`alpha`), then beta, then gamma.
#
# Markdown offers no signal separating that from a genuine wrap, so one of the
# two errors is unavoidable. The false negative is the safe direction: a
# wrapped anchor degrades to `unverifiable`, which is visible in the coverage
# tally and fixed by joining the line. A false failure on correct text is what
# teaches people to stop reading the output.
_ANCHOR = r"(?:[ \t]*\(`(?P<anchor>[^`\n]+)`\))?"
_NAMED = re.compile(
    r"`(?P<path>[\w./-]+\.\w+):(?P<lines>\d+(?:[,-]\d+)*)`" + _ANCHOR
)
# Spelled out rather than derived from `_ANCHOR` by string replacement: the
# two patterns must carry DIFFERENT group names to coexist in one scan, and
# deriving one from the other by `.replace("anchor", ...)` breaks silently the
# day the group is renamed.
_BARE = re.compile(
    r"`:(?P<lines>\d+(?:[,-]\d+)*)`" + r"(?:[ \t]*\(`(?P<banchor>[^`\n]+)`\))?"
)


# Leading whitespace is allowed on both fences: a code block nested in a list
# item is indented to the item's content column, and an anchored-to-column-0
# pattern silently treats those as prose.
# `|\Z`: an unterminated fence runs to the end of the document, per CommonMark.
# Requiring a closing marker left the tail of such a document being checked as
# prose, contradicting the documented rule that fenced citations are skipped.
_FENCE = re.compile(
    r"^[ \t]*(?P<mark>```|~~~)[^\n]*\n.*?(?:^[ \t]*(?P=mark)|\Z)",
    re.MULTILINE | re.DOTALL,
)


def _blank_fences(text: str) -> str:
    """Blank fenced code blocks, preserving offsets so line numbers survive.

    A document that DOCUMENTS this format necessarily contains example
    citations, and a spec's code samples routinely name paths that are
    illustrative rather than claims about the repository -- `driver.py:73` in
    a usage example is not an assertion that `driver.py` exists. Checking
    those produces a finding the author cannot act on, which is how a check
    stops being run at all.

    Newlines are kept and every other character becomes a space, so a match's
    offset still maps to the right line. Removing the blocks instead would
    shift every citation after the first fence.
    """
    return _FENCE.sub(
        lambda m: "".join(c if c == "\n" else " " for c in m.group(0)), text
    )


def _flat(text: str) -> str:
    """Whitespace collapsed, so indentation changes are not drift."""
    return " ".join(text.split())


@dataclass
class Citation:
    line_no: int
    raw: str
    path: str
    lines: str
    anchor: str | None

    def numbers(self) -> list[int]:
        """Every line the citation names. Empty if ANY part names nothing.

        Checking parts individually, not the flattened result: `:5,3-1` used to
        return `[5]`, so the reversed `3-1` -- which names no lines at all --
        was never reported. Unanchored, that is precisely the silent
        "verifies while comparing nothing" case this tool exists to catch.
        """
        out: list[int] = []
        for part in self.lines.split(","):
            if "-" in part:
                lo, hi = part.split("-", 1)
                span = list(range(int(lo), int(hi) + 1))
                if not span:
                    return []
                out.extend(span)
            else:
                out.append(int(part))
        return out


def citations(doc: Path) -> list[Citation]:
    """Every citation in the document, in order, resolving bare continuations.

    Scanned over the WHOLE text rather than line by line so that fenced blocks
    can be blanked before matching, and so match offsets give a single
    document-wide ordering. (It is NOT so that a wrapped anchor is seen -- the
    opposite is true, deliberately: see `_ANCHOR`.)

    That ordering is what the interleave needs: a bare `:47-49` binds to the
    nearest PRECEDING named file, so running all named matches before all bare
    ones would let one bind to a file named later on the same line. A bare
    citation with no preceding named file gets an empty `path` and is reported
    by `check` -- dropping it would hide it from the tally, which is the only
    coverage signal the operator sees.
    """
    text = _blank_fences(doc.read_text(errors="replace"))
    matches = sorted(
        [("named", m) for m in _NAMED.finditer(text)]
        + [("bare", m) for m in _BARE.finditer(text)],
        key=lambda pair: pair[1].start(),
    )

    found: list[Citation] = []
    last_named: str | None = None
    for kind, m in matches:
        if kind == "named":
            last_named = m.group("path")
            path, anchor = m.group("path"), m.group("anchor")
        elif last_named is None:
            found.append(Citation(
                text.count("\n", 0, m.start()) + 1, m.group(0), "", m.group("lines"), None,
            ))
            continue
        else:
            path, anchor = last_named, m.group("banchor")
        line_no = text.count("\n", 0, m.start()) + 1
        # VERBATIM. `raw` is emitted as the `**Claim:**` field, and validate
        # searches the document for that text before editing; text that does
        # not match byte-for-byte is classed as a hallucinated quote, which
        # always blocks. Collapsing runs of whitespace here was enough to turn
        # a correctly-detected stale citation into an unfixable blocked run.
        # A match cannot span a newline (`_ANCHOR` uses `[ \t]*`), so this is
        # always a single line.
        found.append(Citation(line_no, m.group(0), path, m.group("lines"), anchor))
    return found


# Prefix for a `Suggested correction` that is an instruction to a human rather
# than replacement text. validate auto-applies corrections as Edits, so a
# correction it cannot apply must SAY so in the output: applying one of these
# verbatim would replace a citation in the user's spec with an English
# sentence. Only the anchor-moved verdict omits it.
MANUAL = "[manual] "


@lru_cache(maxsize=None)
def tracked(repo: Path) -> tuple[str, ...]:
    """Repo-relative paths git knows about.

    Tracked files, the contents of initialised submodules, and files that are
    new but not ignored.

    Asking git instead of walking the filesystem is not an optimization, it is
    the difference between an allowlist and a denylist. A walk needs a list of
    directories to skip -- `.venv`, `build/lib` shadowing every module in
    `src/`, `node_modules` -- and that list is definitionally incomplete. The
    one that bit this checker was `.claude/worktrees/`: a repo whose own
    worktrees live inside it reported every file as an ambiguous duplicate of
    itself. `.gitignore` already names all of these, correctly, per repo.

    `--others --exclude-standard` keeps files that are new but not ignored, so
    a spec can cite a file added in the same change that has not been staged.
    """
    # Two invocations, unioned: `--recurse-submodules` and `--others` are
    # mutually exclusive in git ("unsupported mode"), but both sets are
    # needed. Without the first, a submodule is one gitlink entry and every
    # citation into it is confidently reported as a nonexistent file --
    # advising the author to delete a correct citation, which is the same
    # "confidently wrong" failure the ambiguity check exists to avoid.
    names: list[str] = []
    for extra in (["--recurse-submodules", "--cached"],
                  ["--others", "--exclude-standard"]):
        result = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z", *extra],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"git ls-files failed in {repo}: {result.stderr.strip()}"
            )
        names.extend(n for n in result.stdout.split("\0") if n)

    return tuple(sorted(set(names)))


@lru_cache(maxsize=None)
def _by_name(repo: Path) -> dict[str, tuple[str, ...]]:
    """Basename -> the tracked paths ending in it. Built once per repo."""
    index: dict[str, list[str]] = {}
    for name in tracked(repo):
        index.setdefault(name.rsplit("/", 1)[-1], []).append(name)
    return {k: tuple(v) for k, v in index.items()}


def normalise(path: str, repo: Path) -> tuple[str, bool]:
    """(path as `git ls-files` spells it, is_root_anchored).

    An absolute path is a natural way to paste a location and used to report
    "no such file" -- a confident denial of a file that is right there.

    A leading `./` is ROOT-ANCHORED, not merely stripped: `./README.md` means
    the repository's own README, not "any README". That gives an author a way
    to write the one-word path they mean and have it resolve, instead of the
    ambiguity error being unfixable without a full path.
    """
    if path.startswith("./"):
        return path[2:], True
    if path.startswith("/"):
        for candidate in (Path(path), Path(path).resolve()):
            try:
                return str(candidate.relative_to(repo)), True
            except ValueError:
                continue
        # Genuinely outside the repo; the miss below is the correct answer.
    return path, False


@lru_cache(maxsize=None)
def gitlinks(repo: Path) -> tuple[str, ...]:
    """Submodule mount points, from the index's mode-160000 entries."""
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--stage", "-z"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return ()
    return tuple(
        entry.split("\t", 1)[1]
        for entry in result.stdout.split("\0")
        if entry.startswith("160000 ") and "\t" in entry
    )


def resolve(path: str, repo: Path) -> tuple[Path | None, list[str]]:
    """(file, ambiguous_candidates). A bare filename must be unambiguous.

    The sharpest failure this catches: six `README.md:NN` citations meant a
    nested README, resolved IN RANGE against the repo-root one, and returned
    plausible content. A checker that follows the wrong file confidently is
    worse than no checker, so ambiguity is an error rather than a guess.
    """
    path, rooted = normalise(path, repo)
    # Indexed by basename rather than scanning every tracked path per
    # citation. `/` + path, never a bare suffix: a citation to `bar.py` must
    # not resolve against `foo/mybar.py`.
    matches = sorted(
        name for name in _by_name(repo).get(path.rsplit("/", 1)[-1], ())
        if name == path or (not rooted and name.endswith("/" + path))
    )
    if not matches:
        return None, []
    if len(matches) > 1:
        return None, matches
    return repo / matches[0], []


def check(cite: Citation, repo: Path) -> tuple[str, str, str]:
    """(verdict, reality, correction). Verdicts: ok, unverifiable, broken."""
    if not cite.path:
        return (
            "broken",
            "This is a bare `:NN` continuation, but no citation naming a file "
            "comes before it, so there is nothing for it to refer to.",
            MANUAL + "Name the file, or move it after the citation it continues.",
        )

    target, candidates = resolve(cite.path, repo)
    if target is None:
        if candidates:
            shown = ", ".join(f"`{c}`" for c in candidates[:4])
            more = "" if len(candidates) <= 4 else f", and {len(candidates) - 4} more"
            # Never echo the cited path back as the suggestion: for
            # `README.md:1` the alphabetically-first candidate IS `README.md`,
            # so the advice read "Qualify the path, e.g. `README.md:1`".
            example = next(
                (c for c in candidates if c != normalise(cite.path, repo)[0]),
                candidates[0],
            )
            return (
                "broken",
                f"`{cite.path}` is ambiguous — {len(candidates)} files match: "
                f"{shown}{more}. A bare filename can resolve in range against "
                f"the wrong file and return plausible content.",
                MANUAL + f"Qualify the path, e.g. `{example}:{cite.lines}`",
            )
        # An uninitialised submodule is what a plain `git clone` leaves
        # behind, and its contents are simply absent from the index. Saying
        # "no such file" there advises deleting a correct citation.
        inside = next(
            (g for g in gitlinks(repo)
             if normalise(cite.path, repo)[0].startswith(g + "/")),
            None,
        )
        if inside is not None:
            return (
                "unverifiable",
                f"`{inside}` is a submodule with no contents checked out, so "
                f"`{cite.path}` cannot be read. The citation may well be "
                f"correct; nothing here can tell.",
                MANUAL + f"Run `git submodule update --init {inside}` and "
                f"re-run, or ignore if submodule contents are out of scope.",
            )
        return (
            "broken",
            f"No file matching `{cite.path}` exists in the repository.",
            MANUAL + "Correct the path, or drop the citation if the file is gone.",
        )

    try:
        body = target.read_text(errors="replace").splitlines()
    except OSError as exc:
        # `--cached` lists index entries, so a file deleted from the worktree
        # but not yet staged resolves here and then fails to open. Uncaught,
        # one such file aborted the entire citation pass with a traceback.
        return (
            "broken",
            f"`{cite.path}` is tracked by git but cannot be read ({exc.strerror}).",
            MANUAL + "Restore the file, or drop the citation if it was deleted.",
        )

    numbers = cite.numbers()

    # Line 0 is not a line. Left alone, `body[0 - 1]` is `body[-1]` -- Python
    # indexes from the end -- so `:0` would silently verify against the LAST
    # line of the file and report ok. A citation that checks the wrong line
    # and passes is worse than one that is merely stale.
    if any(n < 1 for n in numbers):
        return ("broken", "Line numbers start at 1.", MANUAL + "Use a real line number.")
    if not numbers:
        return (
            "broken",
            f"`{cite.lines}` is an empty or reversed line range, so it names nothing.",
            MANUAL + "Write the range low-to-high.",
        )

    beyond = [n for n in numbers if n > len(body)]
    if beyond:
        return (
            "broken",
            f"`{cite.path}` has {len(body)} lines; the citation names line {beyond[0]}.",
            MANUAL + "Re-point the citation, or drop the line number and name the symbol.",
        )

    if cite.anchor is None:
        return ("unverifiable", "", "")

    # Compared with runs of whitespace collapsed, so re-indenting a block does
    # not read as drift. Per line, because an anchor is evidence about ONE
    # line -- that is what makes "it moved to line N" a mechanical correction.
    want = _flat(cite.anchor)
    if not want:
        return (
            "broken",
            "The anchor is empty, so it asserts nothing about the line.",
            MANUAL + "Name the symbol or phrase the line is expected to contain.",
        )

    at = [n for n, text in enumerate(body, start=1) if want in _flat(text)]

    if not at:
        return (
            "broken",
            f"`{cite.anchor}` does not appear anywhere in `{cite.path}`.",
            MANUAL + "Re-anchor the citation to something the file actually contains.",
        )

    # Uniqueness is the property that makes an anchor evidence, and it is
    # measured rather than approximated by a length floor. A floor rejects a
    # short anchor that happens to be unique (which verifies fine) and accepts
    # a long one that appears forty times (which does not): `return None` is
    # eleven characters and identifies nothing, so after the cited code moves,
    # a different `return None` sits at the same line and the citation still
    # "verifies". That is the failure this whole mechanism exists to prevent.
    if len(at) > 1:
        return (
            "broken",
            f"`{cite.anchor}` appears on {len(at)} lines of `{cite.path}` "
            f"({', '.join(str(n) for n in at[:5])}"
            f"{', ...' if len(at) > 5 else ''}), so it identifies no single "
            f"line — if the code moves, a different one of them lands at "
            f"{cite.lines} and the citation still passes.",
            MANUAL + "Extend the anchor until it is unique in the file.",
        )

    if at[0] in numbers:
        return ("ok", "", "")

    # The point of the design: say where it moved to, so the fix is one edit.
    return (
        "broken",
        f"`{cite.anchor}` is at `{cite.path}:{at[0]}`, not at {cite.lines}.",
        f"`{cite.path}:{at[0]}` (`{cite.anchor}`)",
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("document", help="the spec or plan to check")
    ap.add_argument(
        "--repo-root",
        default=None,
        help="repository root citations resolve against (default: the document's repo)",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="also report citations that carry no anchor, as Low findings",
    )
    args = ap.parse_args()

    doc = Path(args.document).resolve()
    if not doc.is_file():
        print(f"check-citations: no such document: {doc}", file=sys.stderr)
        return 2

    if args.repo_root:
        repo = Path(args.repo_root).resolve()
    else:
        result = subprocess.run(
            ["git", "-C", str(doc.parent), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            print("check-citations: not in a git repository", file=sys.stderr)
            return 2
        repo = Path(result.stdout.strip())

    try:
        tracked(repo)
    except RuntimeError as exc:
        print(f"check-citations: {exc}", file=sys.stderr)
        return 2

    tally = {"ok": 0, "unverifiable": 0, "broken": 0}
    blocks: list[str] = []
    for cite in citations(doc):
        verdict, reality, correction = check(cite, repo)
        tally[verdict] += 1
        if verdict == "broken":
            blocks.append(
                f"### Important: citation `{cite.path}:{cite.lines}` does not "
                f"point where it claims\n"
                f"**Location:** {doc.name}:{cite.line_no}\n"
                f"**Claim:** {cite.raw}\n"
                f"**Reality:** {reality}\n"
                f"**Suggested correction:** {correction}\n"
            )
        elif verdict == "unverifiable" and reality:
            # An `unverifiable` that CARRIES text is a real obstruction the
            # operator can act on -- today, an unchecked-out submodule. It is
            # reported unconditionally: `--strict` governs whether merely
            # unanchored citations are noise, not whether the checker may stay
            # silent about something it could not read.
            blocks.append(
                f"### Low: citation `{cite.path}:{cite.lines}` could not be "
                f"checked\n"
                f"**Location:** {doc.name}:{cite.line_no}\n"
                f"**Claim:** {cite.raw}\n"
                f"**Reality:** {reality}\n"
                f"**Suggested correction:** {correction}\n"
            )
        elif verdict == "unverifiable" and args.strict:
            blocks.append(
                f"### Low: citation `{cite.path}:{cite.lines}` carries no anchor\n"
                f"**Location:** {doc.name}:{cite.line_no}\n"
                f"**Claim:** {cite.raw}\n"
                f"**Reality:** The path and line resolve, but nothing records what "
                f"the line is expected to contain, so drift cannot be detected.\n"
                f"**Suggested correction:** {MANUAL}{cite.raw} "
                f"(`SYMBOL` — replace with the real symbol; applying this "
                f"verbatim would write the placeholder into the document)\n"
            )

    total = sum(tally.values())
    print(
        f"<!-- citations: {total} found, {tally['ok']} verified, "
        f"{tally['unverifiable']} unverifiable, {tally['broken']} broken -->"
    )
    print("\n".join(blocks) if blocks else "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
