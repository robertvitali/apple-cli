#!/usr/bin/env python3
"""Validate pull-request title and description metadata."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import unicodedata


APPROVED_TYPES = (
    "feat",
    "fix",
    "docs",
    "style",
    "refactor",
    "perf",
    "test",
    "build",
    "ci",
    "chore",
    "revert",
)
TITLE_PATTERN = re.compile(
    rf"^(?:{'|'.join(APPROVED_TYPES)})(?:\((?P<scope>[a-z0-9._-]+)\))?(?:!)?: "
    r"(?P<description>[^\r\n]+)$"
)
REQUIRED_HEADINGS = ("Rationale", "Details", "Testing", "Checklist")
H2_PATTERN = re.compile(r"^##[ \t]+(.+?)[ \t]*$", flags=re.MULTILINE)
HTML_COMMENT_PATTERN = re.compile(r"<!--.*?-->", flags=re.DOTALL)
PROVENANCE_LINE_PATTERN = re.compile(r"^(?:Reviewed-by|Co-Authored-By):\s+.+$")
TRAILER_LINE_PATTERN = re.compile(
    r"^(?P<key>[A-Za-z][A-Za-z0-9-]*): (?P<value>\S.*)$"
)
UNCHECKED_ITEM_PATTERN = re.compile(r"^[-*+]\s+\[\s\]\s+.+$")
TABLE_SEPARATOR_CELL_PATTERN = re.compile(r"^:?-{3,}:?$")
PLACEHOLDER_LINES = {"...", "describe here", "n/a", "na", "none", "tbd", "todo"}
# Dependabot authorship is asserted from the author account and the head repository, never
# from a branch name (design §10.5). The id is GitHub's public account id for that bot user.
DEPENDABOT_LOGIN = "dependabot[bot]"
DEPENDABOT_ACCOUNT_ID = 49699333
DEPENDABOT_REWRITE_DIAGNOSTIC = (
    "Dependabot pull request: Dependabot authorship is not an exemption; before merging, "
    "replace the generated title and description entirely with the filled-in pull-request "
    "template, keeping none of Dependabot's release notes or commit list, with its provenance "
    "trailers (design §8)"
)
_INTERNAL_TRACKER_NAME = "asa" + "na"
INTERNAL_TRACKER_PATTERNS = (
    re.compile(rf"\b{re.escape(_INTERNAL_TRACKER_NAME)}\s*:", flags=re.IGNORECASE),
    re.compile(
        rf"https?://[^\s/]*{re.escape(_INTERNAL_TRACKER_NAME)}\.com(?:/|\b)",
        flags=re.IGNORECASE,
    ),
    re.compile(r"\bGID(?:[-_ :][A-Z0-9][A-Z0-9_-]*)\b", flags=re.IGNORECASE),
)
TRAILER_PLACEHOLDER_PATTERN = re.compile(
    r"<(?![^>]*@)[^>\r\n]+>|\b(?:TBD|TODO)\b",
    flags=re.IGNORECASE,
)
COAUTHOR_VALUE_PATTERN = re.compile(
    r"^(?P<name>[^<>\s](?:[^<>\r\n]*[^<>\s])?) "
    r"<(?P<local>[A-Z0-9!#$%&'*+/=?^_`{|}~-]+"
    r"(?:\.[A-Z0-9!#$%&'*+/=?^_`{|}~-]+)*)@"
    r"(?P<domain>example\.com|example\.org)>$",
    flags=re.IGNORECASE,
)
PLACEHOLDER_COAUTHOR_NAMES = {
    "author",
    "author name",
    "co-author",
    "co-author name",
    "coauthor",
    "coauthor name",
    "jane doe",
    "john doe",
    "n/a",
    "na",
    "name",
    "none",
    "placeholder",
    "todo",
    "tbd",
    "unknown",
    "your name",
}
CHECKLIST_ITEM_PATTERN = re.compile(
    r"^[ \t]*[-*+][ \t]+\[(?P<state>[ xX])\][ \t]+(?P<item>.+?)[ \t]*\r?$",
    flags=re.MULTILINE,
)
REQUIRED_CHECKLIST_ITEMS = (
    "The PR title follows Conventional Commits.",
    "The change is focused, and the final diff contains no unrelated files.",
    "Tests cover every new or changed behavior.",
    "Exact test commands and results are included above; omitted tests are explained.",
    "Aggregate and changed-line production coverage remain at least 90%, and no production target regresses.",
    "New or changed commands, flags, JSON fields, error envelopes, and exit codes have contract coverage.",
    "Write, dry-run, sandbox, and irreversible-operation behavior is covered where applicable.",
    "Curated manual prose and generated documentation are updated and fresh where applicable.",
    "`[Unreleased]` describes every caller-visible change.",
    "Breaking behavior, `schema_version`, macOS support-baseline, and deployment-minimum effects are disclosed.",
    "Examples, fixtures, and evidence are synthetic and contain no personal data, secrets, private infrastructure details, or internal identifiers.",
    "Dependency changes include their lockfiles, and GitHub Actions remain pinned to full commit SHAs.",
    "`AppleVersion.current` and released CHANGELOG sections were not manually edited.",
    "Generated manual pages came from the generator rather than a hand edit.",
    "Every inapplicable item is explained under Details.",
    "The author reviewed the final diff after the latest push.",
)
# Unicode space separators (general category Zs) other than the space itself. Prose may hold
# them (Option+Space types a no-break space on macOS); headings, the Checklist section and its
# trailers may not, because git, Markdown and this validator would not agree on their meaning.
UNICODE_SPACE_SEPARATORS = (
    "\u00a0\u1680"
    + "".join(chr(code) for code in range(0x2000, 0x200B))
    + "\u202f\u205f\u3000"
)
TITLE_WHITESPACE = " "
PROSE_WHITESPACE = " \t" + UNICODE_SPACE_SEPARATORS
STRUCTURAL_WHITESPACE = " \t"
REFUSED_TITLE_DIAGNOSTIC = (
    "title character U+{:04X} is refused (only a space may be whitespace; no line break, "
    "control character, byte-order mark, bidirectional control or invisible format character)"
)
REFUSED_BODY_DIAGNOSTIC = (
    "body line {}: character U+{:04X} is refused (only a line feed, alone or after a carriage "
    "return, may end a line; no other line break, no control character other than a tab, and no "
    "byte-order mark, bidirectional control, surrogate, U+FFFE or U+FFFF)"
)
REFUSED_STRUCTURAL_DIAGNOSTIC = (
    "body line {}: character U+{:04X} is refused on a line whose first character after any "
    "leading spaces or tabs is # or in the Checklist section (only space and tab may be "
    "whitespace there, and no invisible format character)"
)


def _refused_character(character: str, whitespace: str) -> bool:
    """Whitespace outside `whitespace`, a character outside YAML's printable set (C0 controls,
    a carriage return included, DEL, C1 controls, surrogates, U+FFFE, U+FFFF), a byte-order mark
    (U+FEFF), or a bidirectional control (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069).

    CONTROL PLANE — Python's `str.isspace`, `str.strip`, `str.splitlines` and regex `\\s` accept
    line separators and Unicode spaces that git and Markdown do not, so a title or body holding
    one could pass here while the squash commit git records reads differently (two trailers here,
    one to `git interpret-trailers`). Such text is refused, never interpreted. COUPLING:
    `workflow_policy.refused_character` is the same rule, kept as a copy because the governance
    job executes only this file; `Tests/automation/test_pr_metadata.py` checks they agree.
    """
    if character.isspace():
        return character not in whitespace
    code = ord(character)
    return (code < 0x20 or 0x7F <= code <= 0x9F or 0xD800 <= code <= 0xDFFF or 0x202A <= code <= 0x202E
            or 0x2066 <= code <= 0x2069 or code in (0x061C, 0x200E, 0x200F, 0xFEFF, 0xFFFE, 0xFFFF))


def _first_refused_title_character(title: str) -> int | None:
    """Code point of the first refused title character, else None.

    The title becomes the squash commit's subject line, so it must stay one line to every
    reader: only a space may be whitespace. Invisible format characters (category Cf) are
    refused too, since a reviewer cannot see them in the one line every reader trusts."""
    for character in title:
        if (
            _refused_character(character, TITLE_WHITESPACE)
            or unicodedata.category(character) == "Cf"
        ):
            return ord(character)
    return None


def _first_refused_body_character(body: str) -> tuple[int, int, bool] | None:
    """(line number, code point, structural) of the first refused character in a body whose
    CRLF pairs are already line feeds, else None.

    Lines are split at line feeds only. Prose admits space, tab and the Unicode space
    separators; a structural line (one starting with `#` after spaces and tabs, or any line from
    the `## Checklist` heading on, which holds the checklist items and the terminal trailer
    paragraph) admits only space and tab, and no invisible format character (category Cf), so a
    zero-width character cannot hide inside a heading, a checklist item or a trailer's name."""
    in_checklist = False
    for number, line in enumerate(body.split("\n"), start=1):
        if not in_checklist:
            heading = H2_PATTERN.fullmatch(line)
            in_checklist = heading is not None and heading.group(1) == "Checklist"
        structural = in_checklist or line.lstrip(" \t").startswith("#")
        for character in line:
            if _refused_character(character, PROSE_WHITESPACE):
                return number, ord(character), False
            if structural and (
                _refused_character(character, STRUCTURAL_WHITESPACE)
                or unicodedata.category(character) == "Cf"
            ):
                return number, ord(character), True
    return None


def _contains_internal_tracker_metadata(value: str) -> bool:
    return any(pattern.search(value) for pattern in INTERNAL_TRACKER_PATTERNS)


def _checklist_items(markdown: str) -> list[tuple[str, str]]:
    without_comments = HTML_COMMENT_PATTERN.sub("", markdown)
    return [
        (match.group("state"), match.group("item").strip())
        for match in CHECKLIST_ITEM_PATTERN.finditer(without_comments)
    ]


def _table_cells(line: str) -> list[str] | None:
    if "|" not in line:
        return None
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return cells if len(cells) >= 2 else None


def _is_template_scaffolding(line: str) -> bool:
    if UNCHECKED_ITEM_PATTERN.fullmatch(line):
        return True
    if PROVENANCE_LINE_PATTERN.fullmatch(line):
        return True
    cells = _table_cells(line)
    if cells is not None:
        normalized_cells = [cell.strip("` ").casefold() for cell in cells]
        if not any(normalized_cells):
            return True
        if normalized_cells == ["command", "result"]:
            return True
        if all(TABLE_SEPARATOR_CELL_PATTERN.fullmatch(cell) for cell in normalized_cells):
            return True
    normalized_line = line.strip("`*_>#-.:|[]() ").casefold()
    return normalized_line in PLACEHOLDER_LINES


def _has_substantive_content(content: str) -> bool:
    without_comments = HTML_COMMENT_PATTERN.sub("", content)
    return any(
        line and not _is_template_scaffolding(line)
        for raw_line in without_comments.splitlines()
        if (line := raw_line.strip())
    )


def _has_complete_required_checklist(content: str) -> bool:
    checklist_items = _checklist_items(content)
    for required in REQUIRED_CHECKLIST_ITEMS:
        states = [state for state, item in checklist_items if item == required]
        if len(states) != 1 or states[0].casefold() != "x":
            return False
    return True


def _has_valid_coauthor_value(value: str) -> bool:
    match = COAUTHOR_VALUE_PATTERN.fullmatch(value)
    if match is None:
        return False
    name = match.group("name")
    normalized_name = " ".join(name.casefold().split())
    return (
        any(character.isalnum() for character in name)
        and normalized_name not in PLACEHOLDER_COAUTHOR_NAMES
    )


def _terminal_trailers(body: str) -> list[re.Match[str]]:
    # Lines end at line feeds only and only ASCII blanks are trimmed, as git reads them.
    trailers: list[re.Match[str]] = []
    for line in reversed(body.rstrip(" \t\n").split("\n")):
        match = TRAILER_LINE_PATTERN.fullmatch(line)
        if match is None:
            break
        trailers.append(match)
    trailers.reverse()
    return trailers


def _trailers_follow_an_empty_line(body: str, count: int) -> bool:
    """Whether the last `count` lines are a paragraph of their own: git reads trailers only from
    the final paragraph, so a trailer block joined to the checklist is no trailers to it."""
    lines = body.rstrip(" \t\n").split("\n")
    return len(lines) > count and lines[-count - 1].strip(" \t") == ""


def _without_terminal_lines(content: str, count: int) -> str:
    """`content` without its last `count` lines, split at line feeds only."""
    lines = content.rstrip(" \t\n").split("\n")
    return "\n".join(lines[:-count])


def _has_valid_provenance_order(trailer_keys: list[str]) -> bool:
    reviewed_seen = False
    coauthored_seen = False
    for key in trailer_keys:
        if key == "Reviewed-by":
            if coauthored_seen:
                return False
            reviewed_seen = True
        elif key == "Co-Authored-By":
            if not reviewed_seen:
                return False
            coauthored_seen = True
        elif reviewed_seen:
            return False
    return reviewed_seen


def validate_title(title: str) -> list[str]:
    """Return value-free diagnostics for a pull-request title."""
    refused = _first_refused_title_character(title)
    if refused is not None:
        return [REFUSED_TITLE_DIAGNOSTIC.format(refused)]
    errors = ["title must be at most 72 characters"] if len(title) > 72 else []
    if _contains_internal_tracker_metadata(title):
        errors.append("title contains prohibited internal tracker metadata")
    match = TITLE_PATTERN.fullmatch(title)
    if match is None:
        return errors + ["title must use the required Conventional Commit shape"]
    description = match.group("description")
    if not ("a" <= description[0] <= "z"):
        errors.append("title description must start with a lowercase letter")
    if description != description.strip():
        errors.append("title description must not have surrounding whitespace")
    if description.endswith("."):
        errors.append("title description must not end with a period")
    return errors


def validate_body(body: str) -> list[str]:
    """Return value-free diagnostics for a pull-request description."""
    # A CRLF pair is one line ending to git and Markdown, whichever input path delivered it;
    # any carriage return left after that is refused below, before anything is parsed.
    body = body.replace("\r\n", "\n")
    refused = _first_refused_body_character(body)
    if refused is not None:
        number, code, structural = refused
        template = REFUSED_STRUCTURAL_DIAGNOSTIC if structural else REFUSED_BODY_DIAGNOSTIC
        return [template.format(number, code)]
    errors: list[str] = []
    if _contains_internal_tracker_metadata(body):
        errors.append("body contains prohibited internal tracker metadata")
    heading_matches = list(H2_PATTERN.finditer(body))
    headings = [match.group(1) for match in heading_matches]
    if headings != list(REQUIRED_HEADINGS):
        errors.append("body must contain exactly the required H2 sections in order")
        return errors
    trailers = _terminal_trailers(body)
    for index, (heading, match) in enumerate(zip(REQUIRED_HEADINGS, heading_matches)):
        end = (
            heading_matches[index + 1].start()
            if index + 1 < len(heading_matches)
            else len(body)
        )
        section_content = body[match.end() : end]
        if heading == "Checklist" and trailers:
            section_content = _without_terminal_lines(section_content, len(trailers))
        if not _has_substantive_content(section_content):
            errors.append(f"body {heading} section must contain substantive content")
        if heading == "Checklist" and not _has_complete_required_checklist(
            section_content
        ):
            errors.append(
                "body Checklist must contain each required item exactly once and checked"
            )
    trailer_keys = [match.group("key") for match in trailers]
    if not _has_valid_provenance_order(trailer_keys):
        errors.append("body must end with contiguous provenance trailers in required order")
    if trailers and not _trailers_follow_an_empty_line(body, len(trailers)):
        errors.append("body trailers must follow an empty line, as a paragraph of their own")
    if any(
        not _has_valid_coauthor_value(trailer.group("value"))
        for trailer in trailers
        if trailer.group("key") == "Co-Authored-By"
    ):
        errors.append("coauthor trailers must use the required name and address shape")
    if any(
        TRAILER_PLACEHOLDER_PATTERN.search(trailer.group("value"))
        for trailer in trailers
        if trailer.group("key") in {"Reviewed-by", "Co-Authored-By"}
    ):
        errors.append("provenance trailer values must replace template placeholders")
    return errors


def validate_metadata(title: str, body: str) -> list[str]:
    """Return all value-free pull-request metadata diagnostics."""
    return validate_title(title) + validate_body(body)


def _is_exact_int(value: object) -> bool:
    return type(value) is int


def is_dependabot_proposal(pull_request: object) -> bool:
    """Return whether the event names a Dependabot pull request from this repository.

    Every field must be present with the exact expected type and value, or the answer is
    False. Here the answer only selects an explanatory diagnostic: it never changes the
    verdict, which depends on the title and body alone. COUPLING:
    `dependabot_pin_exception.check_pull_request` does rest a verdict on it, so loosening it
    widens the Dependabot workflow-pin exception.
    """
    if not isinstance(pull_request, dict):
        return False
    user = pull_request.get("user")
    head = pull_request.get("head")
    base = pull_request.get("base")
    if not (isinstance(user, dict) and isinstance(head, dict) and isinstance(base, dict)):
        return False
    head_repo = head.get("repo")
    base_repo = base.get("repo")
    if not (isinstance(head_repo, dict) and isinstance(base_repo, dict)):
        return False
    head_id = head_repo.get("id")
    base_id = base_repo.get("id")
    account_id = user.get("id")
    return (
        user.get("login") == DEPENDABOT_LOGIN
        and user.get("type") == "Bot"
        and _is_exact_int(account_id)
        and account_id == DEPENDABOT_ACCOUNT_ID
        and _is_exact_int(head_id)
        and _is_exact_int(base_id)
        and head_id == base_id
    )


def _read_event(path: Path) -> tuple[str, str, bool]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    pull_request = payload["pull_request"]
    title = pull_request["title"]
    body = pull_request.get("body") or ""
    if not isinstance(title, str) or not isinstance(body, str):
        raise ValueError("invalid pull-request metadata types")
    return title, body, is_dependabot_proposal(pull_request)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--event", "--event-file", dest="event_file", type=Path)
    parser.add_argument("--title")
    parser.add_argument("--body-file", type=Path)
    arguments = parser.parse_args(argv)
    direct_input = arguments.title is not None or arguments.body_file is not None
    dependabot = False
    if direct_input:
        if (
            arguments.event_file is not None
            or arguments.title is None
            or arguments.body_file is None
        ):
            print("error: direct input requires both title and body file", file=sys.stderr)
            return 2
        try:
            # Bytes, then UTF-8: `read_text` would turn a lone carriage return into a line feed,
            # which the event path's JSON keeps, and the two paths must reach one verdict.
            body = arguments.body_file.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            print("error: unable to read pull-request metadata input", file=sys.stderr)
            return 2
        title = arguments.title
    else:
        event_path_value = arguments.event_file or os.environ.get("GITHUB_EVENT_PATH")
        if not event_path_value:
            print("error: pull-request event path is required", file=sys.stderr)
            return 2
        try:
            title, body, dependabot = _read_event(Path(event_path_value))
        except (OSError, KeyError, TypeError, ValueError):
            print("error: unable to read pull-request metadata input", file=sys.stderr)
            return 2
    errors = validate_metadata(title, body)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors and dependabot:
        print(f"error: {DEPENDABOT_REWRITE_DIAGNOSTIC}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
