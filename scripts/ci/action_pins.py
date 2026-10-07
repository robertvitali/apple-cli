#!/usr/bin/env python3
"""Reject mutable or ambiguous GitHub Actions references without YAML dependencies.

The accepted subset uses block mappings and scalar-only flow sequences. Quote complex
scalar values containing YAML structural characters such as colons.

Every remote reference must be the exact pin (name, full commit SHA and version annotation)
recorded in `.github/actions-allowlist.json`, the single approved-Actions source (design
section 18 step 4); `load_allowlist` states its format and which checkout it is read from.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata
from typing import NamedTuple, Optional


REMOTE_PATTERN = re.compile(
    r"(?P<name>[^/@\s]+/[^@\s]+(?:/[^@\s]+)*)@(?P<revision>[0-9a-f]{40})\Z"
)
VERSION_PATTERN = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+\Z")
USES_KEY_PATTERN = re.compile(
    r"^(?P<indent> *)(?P<sequence>- +)?uses(?P<space> *):(?P<rest>.*)$"
)
BLOCK_SCALAR_PATTERN = re.compile(
    r"^(?P<lead> *(?:- +)?)[A-Za-z0-9_-]+: *[|>][+-]? *(?:#.*)?$"
)
QUOTED_MAPPING_KEY_PATTERN = re.compile(
    r'^ *(?:- +)?"(?:\\.|[^"\\])*" *:'
    + r"|^ *(?:- +)?'(?:''|[^'])*' *:"
)
TAG_PATTERN = re.compile(r"(?:^|[\s\[{,:?])!(?!=)")
ANCHOR_ALIAS_PATTERN = re.compile(
    r"(?:^|[\s\[{,:?])(?:&(?=[^\s&])|\*(?=[^\s*]))"
)
EXPLICIT_KEY_PATTERN = re.compile(r"(?:^|[\s\[{,])\?(?=\s|$)")

MAX_WORKFLOW_BYTES = 1024 * 1024

POLICY_ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST_DISPLAY = ".github/actions-allowlist.json"
ALLOWLIST_PATH = POLICY_ROOT / ".github" / "actions-allowlist.json"
MAX_ALLOWLIST_BYTES = 64 * 1024
ALLOWLIST_KEYS = frozenset({"schema_version", "actions"})
ALLOWLIST_ENTRY_KEYS = frozenset({"name", "sha", "version"})
# Lowercase `owner/repository` only: a GitHub owner (alphanumerics and inner hyphens, at most 39
# characters) and a repository that starts with an alphanumeric, so no `.` or `..` segment, no
# path below the repository, no whitespace and no second spelling of a listed name.
ALLOWLIST_NAME_PATTERN = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9][a-z0-9_.-]{0,99}")
FULL_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class ActionReference(NamedTuple):
    path: Path
    line: int
    kind: str
    name: str
    revision: Optional[str]
    version_comment: Optional[str]


def _mask_quoted_scalars_and_comment(line: str) -> str:
    masked = list(line)
    quote: Optional[str] = None
    index = 0
    while index < len(line):
        character = line[index]
        if quote == '"':
            masked[index] = " "
            if character == "\\" and index + 1 < len(line):
                masked[index + 1] = " "
                index += 2
                continue
            if character == '"':
                quote = None
            index += 1
            continue
        if quote == "'":
            masked[index] = " "
            if character == "'" and index + 1 < len(line) and line[index + 1] == "'":
                masked[index + 1] = " "
                index += 2
                continue
            if character == "'":
                quote = None
            index += 1
            continue
        if character in {'"', "'"}:
            quote = character
            masked[index] = " "
            index += 1
            continue
        if character == "#" and (index == 0 or line[index - 1] in " \t"):
            masked[index:] = " " * (len(line) - index)
            break
        index += 1
    return "".join(masked)


def _mask_github_expressions(line: str) -> tuple[str, Optional[str]]:
    masked = list(line)
    cursor = 0
    while True:
        start = line.find("${{", cursor)
        if start < 0:
            return "".join(masked), None
        end = line.find("}}", start + 3)
        if end < 0:
            return "".join(masked), "GitHub expression is unterminated"
        masked[start : end + 2] = " " * (end + 2 - start)
        cursor = end + 2


def _flow_sequence_error(line: str) -> Optional[str]:
    depth = 0
    for character in line:
        if character == "[":
            depth += 1
            continue
        if character == "]":
            if depth == 0:
                return "flow sequence is malformed"
            depth -= 1
            continue
        if character == ":" and depth:
            return (
                "flow sequences must contain only scalars; use block mappings "
                "or quote complex scalar values"
            )
    if depth:
        return "multiline flow sequences are not supported; use block syntax"
    return None


def _canonical_structure_error(line: str) -> Optional[str]:
    if QUOTED_MAPPING_KEY_PATTERN.search(line):
        return "quoted mapping keys are not supported"
    masked, expression_error = _mask_github_expressions(
        _mask_quoted_scalars_and_comment(line)
    )
    if expression_error is not None:
        return expression_error
    if "{" in masked or "}" in masked:
        return "flow mappings are not supported"
    flow_sequence_error = _flow_sequence_error(masked)
    if flow_sequence_error is not None:
        return flow_sequence_error
    if TAG_PATTERN.search(masked):
        return "YAML tags are not supported"
    if ANCHOR_ALIAS_PATTERN.search(masked):
        return "YAML anchors and aliases are not supported"
    if EXPLICIT_KEY_PATTERN.search(masked):
        return "explicit YAML keys are not supported"
    return None


def _workflow_root(root: Path) -> Path:
    return root / ".github" / "workflows"


def workflow_paths(root: Path) -> list[Path]:
    workflows = _workflow_root(root)
    paths = []
    try:
        root_stat = workflows.lstat()
    except OSError:
        return paths
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        return paths
    for directory, names, files in os.walk(str(workflows), followlinks=False):
        names.sort()
        files.sort()
        names[:] = [
            name
            for name in names
            if not (Path(directory) / name).is_symlink()
        ]
        for name in files:
            path = Path(directory) / name
            if path.suffix in {".yml", ".yaml"}:
                paths.append(path)
    return sorted(paths)


def _display_path(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def _split_scalar_and_comment(raw: str) -> tuple[str, Optional[str]]:
    text = raw.strip()
    quote: Optional[str] = None
    escaped = False
    comment_at: Optional[int] = None
    for index, character in enumerate(text):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote == '"':
            escaped = True
            continue
        if quote:
            if character == quote:
                quote = None
            continue
        if character in {"'", '"'}:
            quote = character
            continue
        if character == "#" and (index == 0 or text[index - 1] in " \t"):
            comment_at = index
            break
    if quote:
        raise ValueError("unterminated quoted scalar")
    if comment_at is None:
        scalar = text
        comment = None
    else:
        scalar = text[:comment_at].rstrip()
        comment = text[comment_at + 1 :].strip()
    if len(scalar) >= 2 and scalar[0] == scalar[-1] and scalar[0] in {"'", '"'}:
        scalar = scalar[1:-1]
    elif scalar.startswith(("'", '"')) or scalar.endswith(("'", '"')):
        raise ValueError("malformed quoted scalar")
    return scalar, comment


def _classify(
    path: Path,
    line_number: int,
    scalar: str,
    comment: Optional[str],
    approved: dict[str, tuple[str, str]],
) -> ActionReference:
    if not scalar or scalar in {"|", ">", "|-", ">-", "|+", ">+"}:
        raise ValueError("uses value must be a single-line scalar")
    if "${{" in scalar or "}}" in scalar:
        raise ValueError("expressions are not permitted in uses values")
    if scalar.startswith("./"):
        raise ValueError("local actions and reusable workflows are not approved")
    if scalar.startswith("docker://"):
        raise ValueError("container actions are not approved")
    match = REMOTE_PATTERN.fullmatch(scalar)
    if match is None:
        raise ValueError("remote action must use a full lowercase commit SHA")
    if comment is None or VERSION_PATTERN.fullmatch(comment) is None:
        raise ValueError("remote action must have an adjacent semantic-version annotation")
    pin = approved.get(match.group("name"))
    if pin is None:
        raise ValueError("remote action is not in the reviewed allowlist")
    if pin != (match.group("revision"), comment):
        raise ValueError("remote action pin does not match the reviewed allowlist")
    return ActionReference(
        path,
        line_number,
        "remote",
        match.group("name"),
        match.group("revision"),
        comment,
    )


def _read_regular_utf8(path: Path, maximum_bytes: int) -> str:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(str(path), flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("file must be regular")
        if metadata.st_size > maximum_bytes:
            raise ValueError("file exceeds the size limit")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read(maximum_bytes + 1)
        if len(data) > maximum_bytes:
            raise ValueError("file exceeds the size limit")
        return data.decode("utf-8")
    finally:
        os.close(descriptor)


# Public name for the sibling policy scripts (workflow_policy.py); same contract.
read_regular_utf8 = _read_regular_utf8


def _printable(text: str) -> str:
    """Escape every character that is not printable, so a workflow path holding a line feed cannot
    start a new output line (a line beginning `::` is a runner workflow command). COUPLING:
    `workflow_policy._printable` is the same helper."""
    return "".join(character if character.isprintable() else "\\u{:04x}".format(ord(character)) for character in text)


# Public names for dependabot_pin_exception.py, which splits a pinned `uses:` line and escapes the
# paths it prints exactly as this scan does; same contract. COUPLING: that exception also uses
# USES_KEY_PATTERN, REMOTE_PATTERN, VERSION_PATTERN, MAX_WORKFLOW_BYTES, workflow_paths,
# read_regular_utf8 and load_allowlist, so a change to any of them or to the splitter changes what
# it accepts.
printable = _printable
split_scalar_and_comment = _split_scalar_and_comment


def _refused_character(character: str) -> bool:
    """Whitespace other than space and tab, a character outside YAML's printable set, U+FEFF,
    or a bidirectional control (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069).

    COUPLING: `workflow_policy.refused_character(character, " \t")` is the same rule; keep the
    two in step (`Tests/automation/test_action_pins.py` checks they agree)."""
    if character.isspace():
        return character not in " \t"
    code = ord(character)
    return (code < 0x20 or 0x7F <= code <= 0x9F or 0xD800 <= code <= 0xDFFF or 0x202A <= code <= 0x202E
            or 0x2066 <= code <= 0x2069 or code in (0x061C, 0x200E, 0x200F, 0xFEFF, 0xFFFE, 0xFFFF))


# COUPLING: `workflow_policy.INVISIBLE_OUTSIDE_FORMAT` is the same set.
_INVISIBLE_OUTSIDE_FORMAT = frozenset(
    [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180F, 0x2800, 0x3164, 0xFFA0]
    + list(range(0xFE00, 0xFE10))
    + list(range(0xE0100, 0xE01F0))
)


def _invisible_character(character: str) -> bool:
    """A character a reviewer cannot see: Unicode category Cf, Co or Cn, or one in
    _INVISIBLE_OUTSIDE_FORMAT (the default-ignorable code points outside those categories, and
    U+2800). Refused in a separate pass after `_refused_character`.

    COUPLING: `workflow_policy.invisible_character` is the same rule; keep the two in step
    (`Tests/automation/test_action_pins.py` checks they agree)."""
    category = unicodedata.category(character)
    return category in ("Cf", "Co", "Cn") or ord(character) in _INVISIBLE_OUTSIDE_FORMAT


class _DuplicateKey(Exception):
    """A JSON object repeats a key; `json` would otherwise keep the last value silently."""


def _refuse_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise _DuplicateKey()
    return dict(pairs)


def load_allowlist(path: Path = ALLOWLIST_PATH) -> dict[str, tuple[str, str]]:
    """Read the approved-Actions allowlist as {name: (full commit SHA, version label)}.

    Format, schema_version 1, every rule fail-closed: a regular file (a symlink is refused) of at
    most MAX_ALLOWLIST_BYTES, UTF-8 holding no character `_refused_character` refuses (so no
    byte-order mark and no carriage return) and no invisible character (`_invisible_character`);
    one JSON object, no key repeated at any level, with exactly the keys `schema_version` (the
    integer 1) and `actions`, a non-empty list of objects with exactly the keys `name`
    (ALLOWLIST_NAME_PATTERN), `sha` (40 lowercase hexadecimal characters) and `version` (the
    `vMAJOR.MINOR.PATCH` annotation every `uses:` of that pin carries); names unique and in sorted
    order. A failure raises ValueError with a value-free message naming the file.

    WHICH CHECKOUT. The file is read from this script's own checkout (POLICY_ROOT), never from the
    `--root` under scan, as `quality.py` reads its policy from the policy root and the proposal from
    a separate candidate root: the allowlist is policy, the workflows are what it judges, and a tree
    under scan must not approve its own Actions. Today the two are one checkout wherever the checks
    run: `--root` defaults to this checkout, and on a pull request the Supply-chain policy job checks
    out the proposal, so the proposal's copy of this script reads the proposal's copy of the list (a
    residual design section 10.5 records; until that job's trusted-base conversion, an allowlist
    change rests on control-plane review, which CODEOWNERS names and no ruleset requires yet). Under
    that conversion the base checkout's scripts scan the proposal as data, and reading the list
    beside the script is what makes it the base's committed list. A temporary root that tests fill
    with copied workflows (the urgent-release runbook test's among them) is judged against the
    tracked list, and a scanned root's own `.github/actions-allowlist.json` is ignored. No
    command-line option substitutes another list; callers that need one (tests) pass `path`."""
    label = ALLOWLIST_DISPLAY
    try:
        text = _read_regular_utf8(path, MAX_ALLOWLIST_BYTES)
    except FileNotFoundError:
        raise ValueError(f"{label}: file is missing") from None
    except OSError:
        raise ValueError(f"{label}: must be a readable regular file (a symlink is refused)") from None
    except UnicodeError:
        raise ValueError(f"{label}: must be UTF-8") from None
    except ValueError as error:  # not a regular file, or over the size limit; no value in either
        raise ValueError(f"{label}: {error}") from None
    for line_number, line in enumerate(text.split("\n"), start=1):
        for character in line:
            if _refused_character(character):
                raise ValueError(
                    f"{label}:{line_number}: character U+{ord(character):04X} is refused (only space, "
                    "tab and line feed may be whitespace; no control character, byte-order mark, "
                    "bidirectional control or noncharacter)"
                )
    for line_number, line in enumerate(text.split("\n"), start=1):
        for character in line:
            if _invisible_character(character):
                raise ValueError(
                    f"{label}:{line_number}: character U+{ord(character):04X} is refused (an "
                    "invisible format, private-use, unassigned, default-ignorable or blank character, "
                    "which a reviewer cannot see, such as a variation selector after an emoji)"
                )
    try:
        document = json.loads(text, object_pairs_hook=_refuse_duplicate_keys)
    except _DuplicateKey:
        raise ValueError(f"{label}: a JSON object repeats a key") from None
    except (ValueError, RecursionError) as error:
        position = ""
        if isinstance(error, json.JSONDecodeError):
            position = f" (line {error.lineno}, column {error.colno})"
        raise ValueError(f"{label}: not valid JSON{position}") from None
    if not isinstance(document, dict) or set(document) != ALLOWLIST_KEYS:
        raise ValueError(
            f"{label}: must be one JSON object with exactly the keys `schema_version` and `actions`"
        )
    # `type(...) is int`, not isinstance: JSON `true` loads as a bool, which is an int equal to 1.
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise ValueError(f"{label}: `schema_version` must be the integer 1")
    actions = document["actions"]
    if not isinstance(actions, list) or not actions:
        raise ValueError(f"{label}: `actions` must be a non-empty list")
    approved: dict[str, tuple[str, str]] = {}
    names: list[str] = []
    for number, entry in enumerate(actions, start=1):
        where = f"{label}: `actions` entry {number}"
        if not isinstance(entry, dict) or set(entry) != ALLOWLIST_ENTRY_KEYS:
            raise ValueError(
                f"{where} must be an object with exactly the keys `name`, `sha` and `version`"
            )
        name, sha, version = entry["name"], entry["sha"], entry["version"]
        if not isinstance(name, str) or ALLOWLIST_NAME_PATTERN.fullmatch(name) is None:
            raise ValueError(f"{where}: `name` must be a lowercase owner/repository")
        if not isinstance(sha, str) or FULL_SHA_PATTERN.fullmatch(sha) is None:
            raise ValueError(f"{where}: `sha` must be 40 lowercase hexadecimal characters")
        if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
            raise ValueError(f"{where}: `version` must be a vMAJOR.MINOR.PATCH label")
        if name in approved:
            raise ValueError(f"{where}: `name` repeats an earlier entry")
        approved[name] = (sha, version)
        names.append(name)
    if names != sorted(names):
        raise ValueError(f"{label}: `actions` entries must be sorted by `name`")
    return approved


def _scan_file(
    path: Path, approved: dict[str, tuple[str, str]]
) -> tuple[list[ActionReference], list[tuple[int, str]]]:
    references: list[ActionReference] = []
    errors: list[tuple[int, str]] = []
    active_mapping_keys: dict[int, int] = {}
    block_scalar_indent: Optional[int] = None
    try:
        text = _read_regular_utf8(path, MAX_WORKFLOW_BYTES)
    except (OSError, UnicodeError, ValueError):
        return references, [(1, "workflow must be a regular bounded UTF-8 file")]
    # CONTROL PLANE — whitespace other than space, tab and line feed (a no-break space,
    # another Unicode space, a Unicode line separator, a carriage return), a byte-order mark, a
    # bidirectional control and any character outside YAML's printable set are refused before
    # the line scan, so `splitlines()` and the
    # comment boundary below cannot read a different document than GitHub does. An invisible
    # character (`_invisible_character`) is refused next, so a reviewer sees what runs.
    for line_number, line in enumerate(text.split("\n"), start=1):
        for character in line:
            if _refused_character(character):
                return references, [(
                    line_number,
                    "character U+{:04X} is refused (only space, tab and line feed may be whitespace; "
                    "no control character, byte-order mark, bidirectional control or other character "
                    "outside YAML's printable set)".format(ord(character)),
                )]
    for line_number, line in enumerate(text.split("\n"), start=1):
        for character in line:
            if _invisible_character(character):
                return references, [(
                    line_number,
                    "character U+{:04X} is refused (an invisible format, private-use, unassigned, "
                    "default-ignorable or blank character, which a reviewer cannot see, such as a "
                    "variation selector after an emoji)".format(ord(character)),
                )]
    lines = text.splitlines()

    for line_number, line in enumerate(lines, start=1):
        if "\t" in line[: len(line) - len(line.lstrip())]:
            errors.append((line_number, "workflow indentation contains a tab"))
            continue
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if block_scalar_indent is not None:
            if not stripped or indent > block_scalar_indent:
                continue
            block_scalar_indent = None
        if not stripped or stripped.startswith("#"):
            continue
        active_mapping_keys = {
            key_indent: key_line
            for key_indent, key_line in active_mapping_keys.items()
            if key_indent <= indent
        }
        structure_error = _canonical_structure_error(line)
        if structure_error is not None:
            errors.append((line_number, structure_error))
            continue
        match = USES_KEY_PATTERN.fullmatch(line)
        if match is None:
            if re.match(r"^ *(?:- +)?uses\b", line):
                errors.append((line_number, "uses key is malformed"))
            else:
                block = BLOCK_SCALAR_PATTERN.fullmatch(line)
                if block:
                    # The block's content must sit deeper than the KEY's column: for `- name: |`
                    # that is past the dash, so a `uses:` at the key column is a sibling key.
                    block_scalar_indent = len(block.group("lead"))
            continue

        sequence_item = match.group("sequence") is not None
        if not sequence_item:
            if indent in active_mapping_keys:
                errors.append((line_number, "duplicate uses key in one mapping"))
                continue
            active_mapping_keys[indent] = line_number
        try:
            scalar, comment = _split_scalar_and_comment(match.group("rest"))
            references.append(_classify(path, line_number, scalar, comment, approved))
        except ValueError as error:
            errors.append((line_number, str(error)))
    return references, errors


def collect_references(root: Path, allowlist: Path = ALLOWLIST_PATH) -> list[ActionReference]:
    """The references whose pins match the allowlist; an unreadable allowlist raises ValueError
    (this helper serves tests and inventories; `validate_repository` is the fail-closed check)."""
    approved = load_allowlist(allowlist)
    references: list[ActionReference] = []
    for path in workflow_paths(root):
        found, _ = _scan_file(path, approved)
        references.extend(found)
    return references


def validate_repository(root: Path, allowlist: Path = ALLOWLIST_PATH) -> list[str]:
    try:
        approved = load_allowlist(allowlist)
    except ValueError as error:
        return [str(error)]
    workflows = _workflow_root(root)
    try:
        workflows_stat = workflows.lstat()
    except OSError:
        return [".github/workflows: workflow directory is missing"]
    if stat.S_ISLNK(workflows_stat.st_mode) or not stat.S_ISDIR(workflows_stat.st_mode):
        return [".github/workflows: workflow directory must be regular and non-symlinked"]
    errors: list[str] = []
    for directory, names, _ in os.walk(str(workflows), followlinks=False):
        for name in names:
            path = Path(directory) / name
            if path.is_symlink():
                errors.append(
                    f"{_display_path(root, path)}: workflow directory must not be a symlink"
                )
    for path in workflow_paths(root):
        _, file_errors = _scan_file(path, approved)
        display = _display_path(root, path)
        errors.extend(
            f"{display}:{line_number}: {message}"
            for line_number, message in file_errors
        )
    return errors


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=POLICY_ROOT)
    arguments = parser.parse_args(argv)
    errors = validate_repository(arguments.root.resolve())
    for error in errors:
        print(_printable(error), file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
