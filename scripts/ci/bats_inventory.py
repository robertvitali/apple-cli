#!/usr/bin/env python3
"""Verify the versioned physical partition of Bats test tiers."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import unicodedata
from typing import Any, Callable, Iterable, Optional


SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_BATS_BYTES = 1024 * 1024
MAX_LIVE_FILE_BYTES = 1024 * 1024
MAX_SCAN_FILES = 2048
MAX_SCAN_ENTRIES = 4096
MAX_SCAN_DEPTH = 8
MAX_SCAN_AGGREGATE_BYTES = 64 * 1024 * 1024
TIERS = ("hosted", "local")
TEST_DECLARATION = re.compile(r'^@test "([^"\r\n]+)" \{$')
ALTERNATE_TEST_DECLARATION = re.compile(
    r"^(?:function[ \t]+test_[A-Za-z0-9_]+|test_[A-Za-z0-9_]+[ \t]*\(\))[ \t]*\{"
)
DIGEST = re.compile(r"^[0-9a-f]{64}$")
LIVE_ONLY_HELPERS = (
    "app_lifecycle",
    "assert_live_attachment_enriched",
    "count_sys_folder_rows",
    "load_live_attachment_list",
    "require_index",
    "require_message_id",
    "require_no_stale_session_for",
    "require_osascript_mail_automation",
    "require_unlabeled_message_id",
    "select_live_attachment_fixture",
    "signal_midflight",
)
APP_LIFECYCLE_LOAD = 'load "$HELPERS/app_lifecycle"'
APP_LIFECYCLE_HOOK_IDENTIFIER = re.compile(r"\b(?:setup_file|teardown_file)\b")
LIVE_ONLY_HELPER_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(item) for item in LIVE_ONLY_HELPERS) + r")\b"
)
RESERVED_ROOT_ASSIGNMENT = re.compile(r"(?m)^[ \t]*(?:export[ \t]+)?BATS_ROOT=")
SHARED_ROOT_CONTRACT = (
    'BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"',
    'REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"',
    'HELPERS="$BATS_SUITE_ROOT/helpers"',
)
STALE_NESTED_PATH = re.compile(r"\$BATS_TEST_DIRNAME/(?:helpers|\.\./)")
DIRECT_LIVE_TOOL = re.compile(r"\b(?:sqlite3|osascript)\b")
PROTECTED_LIVE_PATH = re.compile(
    r"(?:\$HOME|\$\{HOME\}|~|/Users/[^/ \t]+)/(?:Library/)?(?:"
    r"Messages|Mail|Calendars|Reminders|Application[ \\]+Support/AddressBook)(?:[/ \t]|$)",
    re.IGNORECASE,
)
SIMPLE_PARAMETER_EXPANSION = re.compile(
    r"(?<!\\)\$\{([A-Za-z_][A-Za-z0-9_]*)(?:\[(?:@|\*)\])?\}"
)
VARIABLE_REFERENCE = re.compile(
    r"(?<!\\)\$([A-Za-z_][A-Za-z0-9_]*)(?:\[(?:@|\*)\])?"
)
SHELL_ARRAY_ASSIGNMENT = re.compile(
    r"(?ms)(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*\((.*?)\)"
)
SHELL_SCALAR_ASSIGNMENT = re.compile(
    r'''(?x)(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*'''
    r'''(?:"([^"\n]*)"|'([^'\n]*)'|([^;\n \t()]+))'''
)
SHELL_WORD = re.compile(
    r"(?<!\\)\$[A-Za-z_][A-Za-z0-9_]*(?:\[(?:@|\*)\])?"
    r"|--[A-Za-z0-9][A-Za-z0-9_-]*"
    r"|[A-Za-z0-9_./:+-]+"
)
SHELL_SEGMENT = re.compile(r"[;\n]|&&?|\|\|?")
CLI_BINARY_MARKER = "__apple_cli_binary__"
MAX_SHELL_VARIANTS = 256
HELPER_DIRECTORY = "bats/helpers"
HELPERS_DEFINITION = SHARED_ROOT_CONTRACT[2]
HELPER_WORD = re.compile(r"(?<![A-Za-z0-9_])helpers(?![A-Za-z0-9_])", re.IGNORECASE)
# What may end a helper file name: a blank, a shell operator or the end of the line.
REFERENCE_END = r"[ \t;|&)<>]|$"
HELPER_REFERENCE_NAME = re.compile(r"/([A-Za-z0-9_][A-Za-z0-9_.-]*)(?=" + REFERENCE_END + ")")
REFERENCE_TERMINATOR = re.compile(REFERENCE_END)
# Command and process substitutions, and bash 5.3's `${ cmd; }` and `${| cmd; }` (whose opener
# may also end a line).
FUNCTION_SUBSTITUTION_OPENERS = ("${ ", "${\t", "${|")
SUBSTITUTION_OPENERS = ("$(", "<(", ">(", *FUNCTION_SUBSTITUTION_OPENERS)
# A logical line ending in an opener continues the substitution onto the lines after it; blanks
# or a `(` may follow the opener, as in `$( (`.
SUBSTITUTION_OPENED_AT_END = re.compile(r"(?:\$\(|<\(|>\(|\$\{[ \t|]?)[ \t(]*$")
# A line that ends in an odd run of backslashes continues on the next one.
CONTINUED_LINE = re.compile(r"(?<!\\)(?:\\\\)*\\$")
# A backtick no backslash escapes: an even run of backslashes before it escapes nothing.
UNESCAPED_BACKTICK = re.compile(r"(?<!\\)(?:\\\\)*`")
PLAIN_PATH_CHARACTER = re.compile(r"[A-Za-z0-9_./-]")
SAFE_REPOSITORY_PATH = re.compile(
    r"[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*"
)
INVENTORY_SCRIPT = "scripts/ci/bats_inventory.py"
PIN_MAP_NAMES = ("TRUSTED_HOSTED_FILE_SHA256", "TRUSTED_HOSTED_HELPER_SHA256")
CI_ENVIRONMENT_FLAGS = ("CI", "GITHUB_ACTIONS")
UPDATE_HINT = (
    "if the change is reviewed and intended, re-pin locally, never in CI: run "
    f"`python3 {INVENTORY_SCRIPT} --update-shas` from the repository root, after bringing "
    "bats/tier-inventory.json up to date if it reports manifest drift, and review the diff"
)
RENAME_HINT = "rename it to plain [A-Za-z0-9_./-] path text first: --update-shas pins no other"
PULL_REQUEST_PIN_NOTE = (
    "in a pull request the base branch's copy of this script and its pins judge the candidate, "
    "and a pull request cannot change a hosted file or a pinned helper: re-pinning lands only "
    "through a reviewed change on main"
)
# Both maps are rewritten by `--update-shas` (see `update_trusted_shas` for its trust model);
# keep each one a single literal in this exact format, one sorted entry per line, bind neither
# name anywhere else in this script, and read each only by its bare name, never through an
# attribute, an item store or a call argument (`_verified_pin_literals` refuses otherwise). An
# alias is beyond that check, so keep any alias read-only.
TRUSTED_HOSTED_FILE_SHA256 = {
    "bats/hosted/bounded_exec.bats": "ccfbd511de8bcd38e3c8f0eb73e2b4a051b1585c6b3a34ae09faf8d906a6bc95",
    "bats/hosted/calendar.bats": "f9959a2b94f5869d46d20c1be5500f4e244f1d0e5e3dd198f16f6e712ab11613",
    "bats/hosted/contacts.bats": "e9a4adf121fa3d78a7890aedbd1fe6a4d2737bd86efa91f96fde9880a0cec03b",
    "bats/hosted/mail.bats": "e120826145b1ecfa2ffb6f9aee9fd9f91f96c6aea0ed055d7ea37483f07e93b6",
    "bats/hosted/messages.bats": "23a087ee666d59ad74899ca98186feebd5b20f2db24b0804c5a5c456b8c5cf40",
    "bats/hosted/notes.bats": "489bf4d9a7e1d1dea5e038e36c58e200f35f1b299c058ace927f4a1865db5580",
    "bats/hosted/reminders.bats": "e195ea49c1205b3fbe15d275a109f4591776093f3e743f21e36cb9c7682de3f4",
    "bats/hosted/smoke.bats": "31b1904e4aed2228876f052c1e7e74c8d1530fd24230b2812015159b35710edc",
}
TRUSTED_HOSTED_HELPER_SHA256 = {
    "bats/helpers/app_lifecycle.bash": "4e9689b18532ad592e3e6166a141ad0cae16a2d1bfe0d02b3160ca9c3753781a",
    "bats/helpers/app_lifecycle.py": "bb8f8cbcc78f821fe9a4d59c984f7aa4b3c4fa2719a9885796bea40d0446ead5",
    "bats/helpers/applescript_syntax_check.py": "40f56f5659dfb3bbc4c8b4b36d30ac12ad943f7c3fd78981800f3da46343e996",
    "bats/helpers/bounded_exec.py": "cc3f72c2cc407e51b637a459b530d6767c1a8649d2c47be8073ef3a1d6adfaf0",
    "bats/helpers/execute_envelope_lint.py": "430eba15fea468da6415441657087f7f2b70b0e6853ae70777c7b52a652454ba",
    "bats/helpers/md_tables_wellformed.py": "2ee916ec014906507474d7a63d89eb2538d277b628aedf404a87fbb448e4f49a",
    "bats/helpers/messages_db_probe.py": "da7daca3cf7fd967f3b00cea30724ea8b99411d6879458ee8caeb143ffc290e2",
    "bats/helpers/no_flagless_writes.py": "6c238da220f8c599afda95741a93142ab02febc6f35890100e7711d408534c39",
    "bats/helpers/queue_table_wellformed.py": "4adbf9c0eee8e15c12cb131177bd7fcda12edcd1e286d93eb2756525b6a60369",
    "bats/helpers/quoted_not_found.py": "3a32f34ffa0ef59cff0c29d1df29affddb26bb7b8840b142d1a951f90b826d21",
    "bats/helpers/subcommand_allowlist.py": "31f24f90a3a7865f7de99bdcab45170ab147bf0d477059969b92c3e34e93c6c2",
}


class InventoryError(ValueError):
    """Raised when inventory input is malformed."""


def _display_path(relative: str) -> str:
    """A repository path for a diagnostic: shown only when it is plain ASCII path text, so no
    control, quote or other character a terminal could act on is ever echoed."""
    if SAFE_REPOSITORY_PATH.fullmatch(relative):
        return relative
    return "a path outside [A-Za-z0-9_./-]"


def _read_bounded_regular(path: Path, *, label: str, maximum: int) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if path.is_symlink():
        raise InventoryError(f"{label} is not a regular file")
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        raise InventoryError(f"{label} is not a regular file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise InventoryError(f"{label} is not a regular file")
        if metadata.st_size > maximum:
            raise InventoryError(f"{label} is too large")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(payload) > maximum:
        raise InventoryError(f"{label} is too large")
    if len(payload) != metadata.st_size:
        raise InventoryError(f"{label} changed while being read")
    return payload


def _refused_character(character: str) -> bool:
    """Whitespace other than space and tab, a C0 or C1 control (a carriage return included),
    DEL, a surrogate, U+FFFE, U+FFFF, U+FEFF, or a bidirectional control (U+061C, U+200E,
    U+200F, U+202A-U+202E, U+2066-U+2069).

    CONTROL PLANE — bash reads lines at a line feed only and treats only a space and a tab as
    blanks, so a no-break space before `#` does not start a comment there. Python's
    `str.isspace`, `str.strip`, `str.splitlines` and regex `\\s` also accept the no-break space,
    the other Unicode spaces and several line separators, which would let this inventory read
    a different file than bash and bats do. Such a character is refused, never interpreted.
    COUPLING: `workflow_policy.refused_character(character, " \\t")` is the same rule; keep the
    two in step (`Tests/automation/test_bats_inventory.py` checks they agree)."""
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
    """A character a reviewer cannot see: Unicode category Cf (the zero-width space, the joiners,
    the soft hyphen and the rest), a private-use (Co) or unassigned (Cn) code point, or one in
    _INVISIBLE_OUTSIDE_FORMAT (the default-ignorable code points outside those categories, and
    U+2800). bash treats it as neither a blank nor a line break, so it moves no token boundary,
    but it can make the file a code owner reviews look different from what runs, so it is
    refused, never interpreted.

    COUPLING: `workflow_policy.invisible_character` is the same rule; keep the two in step
    (`Tests/automation/test_bats_inventory.py` checks they agree)."""
    category = unicodedata.category(character)
    return category in ("Cf", "Co", "Cn") or ord(character) in _INVISIBLE_OUTSIDE_FORMAT


def _first_invisible_character(source: str) -> Optional[tuple[int, int]]:
    """(line number, code point) of the first invisible character, else None."""
    for line_number, line in enumerate(source.split("\n"), 1):
        for character in line:
            if _invisible_character(character):
                return line_number, ord(character)
    return None


def _first_refused_character(source: str) -> Optional[tuple[int, int]]:
    """(line number, code point) of the first refused character, else None. Line feeds split
    the lines; inside a line only a space and a tab are admitted whitespace."""
    for line_number, line in enumerate(source.split("\n"), 1):
        for character in line:
            if _refused_character(character):
                return line_number, ord(character)
    return None


def _refuse_characters(source: str, label: str) -> None:
    """Raise before any tokenising; the diagnostic names the line and code point, never text."""
    refused = _first_refused_character(source)
    if refused is not None:
        line_number, code = refused
        raise InventoryError(
            f"{label} line {line_number} contains refused character U+{code:04X} "
            "(only space, tab and line feed may be whitespace; no control, byte-order mark "
            "or bidirectional control)"
        )
    invisible = _first_invisible_character(source)
    if invisible is not None:
        line_number, code = invisible
        raise InventoryError(
            f"{label} line {line_number} contains refused character U+{code:04X} "
            "(an invisible format, private-use, unassigned, default-ignorable or blank character, "
            "which a reviewer cannot see, such as a variation selector after an emoji)"
        )


def _lf_lines(source: str) -> list[str]:
    """The lines bash reads: split at line feeds only, with no final empty line after a trailing
    line feed (as `str.splitlines` gives). `str.splitlines` also breaks at U+2028, U+2029,
    U+0085, a carriage return and other characters that bash keeps inside one line."""
    lines = source.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def _strict_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InventoryError("inventory manifest contains a duplicate JSON key")
        result[key] = value
    return result


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        source = _read_bounded_regular(
            path,
            label="inventory manifest",
            maximum=MAX_MANIFEST_BYTES,
        ).decode("utf-8")
    except UnicodeError as error:
        raise InventoryError("inventory manifest is not valid UTF-8 JSON") from error
    try:
        manifest = json.loads(source, object_pairs_hook=_strict_object)
    except InventoryError:
        raise
    except (json.JSONDecodeError, UnicodeError) as error:
        raise InventoryError("inventory manifest is not valid UTF-8 JSON") from error
    if not isinstance(manifest, dict):
        raise InventoryError("inventory manifest root must be an object")
    return manifest


def _relative_manifest_path(value: Any, tier: str) -> str:
    if not isinstance(value, str) or not value:
        raise InventoryError(f"{tier} inventory path must be a non-empty string")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise InventoryError(f"{tier} inventory path must be repository-relative")
    expected_prefix = ("bats", tier)
    if path.parts[:2] != expected_prefix or path.suffix != ".bats":
        raise InventoryError(f"{tier} inventory path must be under bats/{tier}")
    return path.as_posix()


def _safe_file(root: Path, relative: str) -> Path:
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    if candidate.is_symlink() or not candidate.is_file():
        raise InventoryError("inventory file is missing or not a regular file")
    try:
        candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise InventoryError("inventory file escapes the repository") from error
    return candidate


def _scan_shell_line(
    line: str,
    quote: Optional[str],
    heredocs: list[tuple[str, bool]],
    relative: str,
    line_number: int,
    code: Optional[list[str]] = None,
) -> Optional[str]:
    index = 0
    while index < len(line):
        character = line[index]
        if quote is not None:
            if code is not None:
                code.append(" ")
            if character == quote:
                quote = None
            elif character == "\\" and quote != "'":
                if code is not None and index + 1 < len(line):
                    code.append(" ")
                index += 1
            index += 1
            continue

        if character in ("'", '"', "`"):
            if code is not None:
                code.append(" ")
            quote = character
            index += 1
            continue
        if character == "\\":
            if code is not None:
                code.extend("  ")
            index += 2
            continue
        if character == "#" and (
            index == 0 or line[index - 1] in " \t;|&()"
        ):
            break
        if line.startswith("<<<", index):
            index += 3
            continue
        if line.startswith("<<", index):
            cursor = index + 2
            strip_tabs = False
            if cursor < len(line) and line[cursor] == "-":
                strip_tabs = True
                cursor += 1
            while cursor < len(line) and line[cursor] in " \t":
                cursor += 1
            if cursor >= len(line):
                raise InventoryError("unsupported heredoc declaration in Bats file")
            delimiter_quote = line[cursor] if line[cursor] in ("'", '"') else None
            if delimiter_quote is not None:
                end = line.find(delimiter_quote, cursor + 1)
                if end < 0:
                    raise InventoryError("unsupported heredoc declaration in Bats file")
                delimiter = line[cursor + 1 : end]
                cursor = end + 1
            else:
                if line[cursor] == "\\":
                    cursor += 1
                match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", line[cursor:])
                if match is None:
                    raise InventoryError("unsupported heredoc declaration in Bats file")
                delimiter = match.group(0)
                cursor += len(delimiter)
            heredocs.append((delimiter, strip_tabs))
            if code is not None:
                code.extend(" " * (cursor - index))
            index = cursor
            continue
        if code is not None:
            code.append(character)
        index += 1
    return quote


def _parse_bats_source(source: str, relative: str) -> tuple[str, ...]:
    """The ordered `@test` titles bats declares in `source`.

    The character refusal runs first, before any tokenising, so every caller is covered:
    `read_bats_file` here, and `capability_policy` and `bats_evidence`, which call this parser
    directly (a refusal is an `InventoryError` that each maps to its own value-free code)."""
    _refuse_characters(source, "Bats file")
    lines = _lf_lines(source)
    titles: list[str] = []
    quote: Optional[str] = None
    heredocs: list[tuple[str, bool]] = []
    for line_number, line in enumerate(lines, 1):
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            continue

        if quote is None:
            declaration = TEST_DECLARATION.fullmatch(line)
            if declaration is not None:
                titles.append(declaration.group(1))
            else:
                stripped = line.lstrip()
                if stripped.startswith("@test") or ALTERNATE_TEST_DECLARATION.match(stripped):
                    raise InventoryError("unknown @test declaration syntax in Bats file")
        quote = _scan_shell_line(line, quote, heredocs, relative, line_number)

    if heredocs or quote is not None:
        raise InventoryError("unterminated shell construct in Bats file")

    if not titles:
        raise InventoryError("inventory file contains no tests")
    if len(titles) != len(set(titles)):
        raise InventoryError("inventory file contains a duplicate test title")
    return tuple(titles)


def _local_lifecycle_errors(source: str, relative: str) -> tuple[str, ...]:
    quote: Optional[str] = None
    heredocs: list[tuple[str, bool]] = []
    prologue_valid = True
    header_index = 0
    has_top_level_load = False
    executable_lines: list[str] = []

    for line_number, line in enumerate(_lf_lines(source), 1):
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            continue

        if not has_top_level_load:
            if (
                line == APP_LIFECYCLE_LOAD
                and prologue_valid
                and quote is None
                and header_index == len(SHARED_ROOT_CONTRACT)
            ):
                has_top_level_load = True
            elif (
                line.strip(" \t") == ""
                or line.lstrip(" \t").startswith("#")
            ):
                pass
            elif (
                prologue_valid
                and header_index < len(SHARED_ROOT_CONTRACT)
                and line == SHARED_ROOT_CONTRACT[header_index]
            ):
                header_index += 1
            else:
                prologue_valid = False

        code: list[str] = []
        quote = _scan_shell_line(
            line,
            quote,
            heredocs,
            relative,
            line_number,
            code,
        )
        executable_lines.append("".join(code))

    errors: list[str] = []
    if not has_top_level_load:
        errors.append(
            "local file does not load executable top-level app lifecycle hook "
            "after ordered header"
        )
    if APP_LIFECYCLE_HOOK_IDENTIFIER.search("\n".join(executable_lines)):
        errors.append("local file overrides app lifecycle hook")
    return tuple(errors)


def read_bats_file(path: Path, relative: str) -> tuple[bytes, str, tuple[str, ...]]:
    try:
        payload = _read_bounded_regular(
            path,
            label="Bats file",
            maximum=MAX_BATS_BYTES,
        )
        source = payload.decode("utf-8")
    except UnicodeError as error:
        raise InventoryError("unable to read Bats file") from error
    # `_parse_bats_source` refuses a misleading character before it tokenises, and the source
    # is returned for the other readers only after that refusal has passed.
    return payload, source, _parse_bats_source(source, relative)


def _discover_bats_count(path: Path, relative: str) -> int:
    try:
        source = _read_bounded_regular(
            path,
            label="Bats file",
            maximum=MAX_BATS_BYTES,
        ).decode("utf-8")
    except UnicodeError as error:
        raise InventoryError("unable to read Bats file") from error
    _refuse_characters(source, "Bats file")

    count = 0
    quote: Optional[str] = None
    heredocs: list[tuple[str, bool]] = []
    for line_number, line in enumerate(_lf_lines(source), 1):
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            continue
        if quote is None:
            declaration = TEST_DECLARATION.fullmatch(line)
            if declaration is not None:
                count += 1
            else:
                stripped = line.lstrip()
                if stripped.startswith("@test") or ALTERNATE_TEST_DECLARATION.match(stripped):
                    raise InventoryError("unknown @test declaration syntax in Bats file")
        quote = _scan_shell_line(line, quote, heredocs, relative, line_number)
    if heredocs or quote is not None:
        raise InventoryError("Bats discovery failed")
    if count == 0:
        raise InventoryError("Bats discovery found no tests")
    return count


def _title_digests(titles: Iterable[str]) -> tuple[str, ...]:
    return tuple(hashlib.sha256(title.encode("utf-8")).hexdigest() for title in titles)


def _normalize_parameter_expansions(source: str) -> str:
    return SIMPLE_PARAMETER_EXPANSION.sub(lambda match: f"${match.group(1)}", source)


def _canonical_shell_word(word: str) -> str:
    if word == "apple" or word.endswith("/apple"):
        return CLI_BINARY_MARKER
    return word


def _shell_words(source: str) -> tuple[str, ...]:
    normalized = _normalize_parameter_expansions(source)
    return tuple(_canonical_shell_word(word) for word in SHELL_WORD.findall(normalized))


def _assignment_word_sets(
    source: str,
) -> tuple[dict[str, set[tuple[str, ...]]], bool]:
    assignments: list[tuple[str, tuple[str, ...]]] = []
    for match in SHELL_ARRAY_ASSIGNMENT.finditer(source):
        raw_value = match.group(2)
        if "$(" not in raw_value and "`" not in raw_value:
            assignments.append((match.group(1), _shell_words(raw_value)))
    for match in SHELL_SCALAR_ASSIGNMENT.finditer(source):
        raw_value = next(value for value in match.groups()[1:] if value is not None)
        if "$(" not in raw_value and "`" not in raw_value:
            assignments.append((match.group(1), _shell_words(raw_value)))

    values: dict[str, set[tuple[str, ...]]] = {
        "BIN": {(CLI_BINARY_MARKER,)},
    }
    overflow = False
    for _ in range(len(assignments) + 1):
        changed = False
        for name, words in assignments:
            if name == "BIN" or not words:
                continue
            variants: set[tuple[str, ...]] = {()}
            unresolved = False
            for word in words:
                reference = VARIABLE_REFERENCE.fullmatch(word)
                options = values.get(reference.group(1)) if reference else {(word,)}
                if not options:
                    unresolved = True
                    break
                expanded = {
                    prefix + option
                    for prefix in variants
                    for option in options
                }
                if len(expanded) > MAX_SHELL_VARIANTS:
                    overflow = True
                    break
                variants = expanded
            if overflow:
                break
            if unresolved:
                continue
            current = values.setdefault(name, set())
            before = len(current)
            current.update(variants)
            if len(current) > MAX_SHELL_VARIANTS:
                overflow = True
                break
            changed = changed or len(current) != before
        if overflow or not changed:
            break
    return values, overflow


def _expanded_shell_variants(
    words: tuple[str, ...],
    values: dict[str, set[tuple[str, ...]]],
) -> tuple[set[tuple[str, ...]], bool]:
    variants: set[tuple[str, ...]] = {()}
    for word in words:
        reference = VARIABLE_REFERENCE.fullmatch(word)
        options = values.get(reference.group(1)) if reference else None
        if not options:
            options = {(word,)}
        expanded = {
            prefix + option
            for prefix in variants
            for option in options
        }
        if len(expanded) > MAX_SHELL_VARIANTS:
            return set(), True
        variants = expanded
    return variants, False


def _variant_has_live_cli_operation(words: tuple[str, ...]) -> bool:
    for index, word in enumerate(words):
        if word != CLI_BINARY_MARKER:
            continue
        arguments = words[index + 1 :]
        if "--help" in arguments or "--version" in arguments:
            continue
        operands = tuple(item for item in arguments if not item.startswith("-"))
        if not operands or operands[0] == "help" or len(operands) == 1:
            continue
        return True
    return False


def _has_live_cli_operation(source: str) -> bool:
    values, overflow = _assignment_word_sets(source)
    if overflow:
        return True
    for segment in SHELL_SEGMENT.split(source):
        words = _shell_words(segment)
        if not words:
            continue
        command_index: Optional[int] = None
        if words[0] == "run" and len(words) > 1:
            command_index = 1
        elif VARIABLE_REFERENCE.fullmatch(words[0]):
            command_index = 0
        if command_index is not None:
            command_reference = VARIABLE_REFERENCE.fullmatch(words[command_index])
            if (
                command_reference is not None
                and command_reference.group(1) not in values
            ):
                return True
        variants, overflow = _expanded_shell_variants(words, values)
        if overflow or any(_variant_has_live_cli_operation(item) for item in variants):
            return True
    return False


def _expanded_scalar_strings(source: str) -> tuple[set[str], bool]:
    assignments = []
    for match in SHELL_SCALAR_ASSIGNMENT.finditer(source):
        raw_value = next(value for value in match.groups()[1:] if value is not None)
        if "$(" not in raw_value and "`" not in raw_value:
            assignments.append((match.group(1), _normalize_parameter_expansions(raw_value)))

    values: dict[str, set[str]] = {"HOME": {"$HOME"}}
    all_values: set[str] = set()
    for _ in range(len(assignments) + 1):
        changed = False
        for name, raw_value in assignments:
            variants = {""}
            cursor = 0
            unresolved = False
            for reference in VARIABLE_REFERENCE.finditer(raw_value):
                literal = raw_value[cursor : reference.start()]
                options = values.get(reference.group(1))
                if options is None:
                    unresolved = True
                    break
                variants = {
                    prefix + literal + option
                    for prefix in variants
                    for option in options
                }
                if (
                    len(variants) > MAX_SHELL_VARIANTS
                    or any(len(item) > MAX_BATS_BYTES for item in variants)
                ):
                    return set(), True
                cursor = reference.end()
            if unresolved:
                continue
            suffix = raw_value[cursor:]
            variants = {item + suffix for item in variants}
            current = values.setdefault(name, set())
            before = len(current)
            current.update(variants)
            if len(current) > MAX_SHELL_VARIANTS:
                return set(), True
            all_values.update(variants)
            changed = changed or len(current) != before
        if not changed:
            break
    return all_values, False


def _hosted_has_live_state_access(source: str) -> bool:
    executable_lines = [
        line for line in _lf_lines(source) if not line.lstrip(" \t").startswith("#")
    ]
    executable = re.sub(r"\\[ \t]*\n", " ", "\n".join(executable_lines))
    policy_source = "\n".join(
        line for line in _lf_lines(executable) if line not in SHARED_ROOT_CONTRACT
    )
    if "$(" in policy_source or "`" in policy_source:
        return True
    dequoted = executable.replace("'", "").replace('"', "")
    scalar_values, overflow = _expanded_scalar_strings(executable)
    if overflow:
        return True
    if (
        DIRECT_LIVE_TOOL.search(dequoted)
        or PROTECTED_LIVE_PATH.search(dequoted)
        or any(PROTECTED_LIVE_PATH.search(value) for value in scalar_values)
    ):
        return True
    return _has_live_cli_operation(executable) or _has_live_cli_operation(dequoted)


def _logical_lines(source: str) -> list[tuple[int, str]]:
    """(first line number, text) for each logical line: a line ending in an odd run of
    backslashes continues on the next, and the backslash and line feed go, as bash joins them."""
    logical: list[tuple[int, str]] = []
    start, pieces = 0, []
    for line_number, line in enumerate(_lf_lines(source), 1):
        if not pieces:
            start = line_number
        if CONTINUED_LINE.search(line):
            pieces.append(line[:-1])
            continue
        logical.append((start, "".join(pieces) + line))
        pieces = []
    if pieces:
        logical.append((start, "".join(pieces)))
    return logical


def _substitution_reading(text: str) -> tuple[bool, bool]:
    """(the logical line holds a substitution, it leaves one open for the lines after it: it
    ends with an opener, which blanks or a `(` may follow, or holds an odd number of unescaped
    backticks)."""
    holds = "`" in text or any(opener in text for opener in SUBSTITUTION_OPENERS)
    opens = SUBSTITUTION_OPENED_AT_END.search(text) is not None or (
        len(UNESCAPED_BACKTICK.findall(text)) % 2 == 1
    )
    return holds or opens, opens


def _first_unclosed_substitution(source: str) -> Optional[int]:
    """The first line of the first logical line that leaves a substitution open for later lines."""
    for start, text in _logical_lines(source):
        if _substitution_reading(text)[1]:
            return start
    return None


def _helper_references(
    source: str, *, sticky: bool = True
) -> tuple[frozenset[str], tuple[int, ...]]:
    """(file names a hosted file runs from `bats/helpers`, lines using the word otherwise).

    The reader works on logical lines (a line ending in a backslash joined to the next, as bash
    joins them; a refused line is reported by the first line of its logical line), comments,
    strings and heredoc bodies included, in two readings: with quotes removed, and with quotes
    and backslashes removed (bash reads an unquoted `hel\\pers` as `helpers`); `${NAME}` reads as
    `$NAME` in both, so `"$HELPERS"/x.py` and `${HELPERS}/x.py` read as `$HELPERS/x.py`. Each
    occurrence of the word `helpers`, in any case (macOS paths ignore case), must be a reference:
    the variable `$HELPERS` (that exact name) or a path component (`.../helpers`, or `helpers`
    followed by `/`), then `/` and one plain file name (a letter, digit or `_`, then letters,
    digits, `_`, `.` and `-`) that ends the word, as in `"$HELPERS/x.py"` or `"$0/helpers/x.py"`,
    outside any substitution, since a substitution's output can extend or replace the path the
    name spells (`$(dirname "$HELPERS/x.py")/y.py` runs `y.py`). A logical line that holds `$(`,
    `<(`, `>(`, `${` and a blank, `${|` or a backtick refuses every reference on it, and so does
    any name followed by `)` and more than a terminator. A logical line that ends with one of those
    openers (blanks or a `(` may follow it, as in `$( (`), or holds an odd number of unescaped
    backticks, continues a substitution onto the lines after it, and refuses every reference
    after it in the file, since the reader does not look for where it ends. `sticky=False`
    reads each line as if no earlier line had left one open: diagnostics use it to tell which
    lines that refusal alone stops, and it never decides what is credited. The shared-root
    definition line is the one other place the word may appear. A comment is no exception: the
    reader does not model every bash quoting form, so it cannot be sure which lines bash reads as
    comments.
    FAIL-CLOSED: every other occurrence is an ambiguous line, refused and never resolved:
    `"$HELPERS"` alone, `$HELPERS/$name`, a subdirectory, a glob, the bare directory, another
    variable such as `$helpers`, `dir=helpers`, `cd helpers`, an assignment to `HELPERS`, a
    quoted 'helpers' in an embedded script, a reference inside or beside a substitution or after
    a line that leaves one open, or the word in any comment.
    RESIDUAL: the reader credits the file NAME a reference spells. It does not prove that what
    precedes `/helpers/` is the suite's helper directory; it does not follow a reference used as the
    input of a command outside a substitution (`sed` or `xargs` in a pipeline), whose output is what
    runs; it does not see a substitution opened mid-line that continues onto later lines (its first
    line ends with other text, as a multi-line `python3 -c '...'` argument inside `$(...)` does, or
    as an opener does that a continuation joins to more text), or one whose opener quotes split; a
    backtick that is not shell syntax (quoted, or in a comment or heredoc body) counts, so it can
    refuse later lines or pair with a real one and hide the substitution that one opens, and a line
    ending in a backslash is joined to the next even in a comment, inside single quotes or in a
    quoted heredoc body, where bash does not join it; and a path that never spells the word (built
    from pieces or an encoding, a glob over the suite root, a file outside `bats/helpers`) is beyond
    it too. The hosted file's own content pin is what makes such a change visible to review. A
    helper's own source is Python or bash this reader does not parse, so a helper that runs another
    is not traced: each helper's content pin covers what it runs."""
    names: set[str] = set()
    ambiguous: set[int] = set()
    unclosed = False
    for line_number, line in _logical_lines(source):
        holds, opens = _substitution_reading(line)
        refused = holds or (unclosed and sticky)
        unclosed = unclosed or opens
        if line == HELPERS_DEFINITION:
            continue
        dequoted = line.replace("'", "").replace('"', "")
        readings = {
            _normalize_parameter_expansions(dequoted),
            _normalize_parameter_expansions(dequoted.replace("\\", "")),
        }
        for text in readings:
            for match in HELPER_WORD.finditer(text):
                start, end = match.span()
                before = text[start - 1 : start]
                reference = None
                if text.startswith("/", end) and (before != "$" or match.group(0) == "HELPERS"):
                    reference = HELPER_REFERENCE_NAME.match(text, end)
                if (
                    reference is not None
                    and not refused
                    and (
                        not text.startswith(")", reference.end())
                        or REFERENCE_TERMINATOR.match(text, reference.end() + 1)
                    )
                ):
                    names.add(reference.group(1))
                else:
                    ambiguous.add(line_number)
    return frozenset(names), tuple(sorted(ambiguous))


def _helper_candidates(name: str) -> tuple[str, str]:
    """The files a reference to `name` can run: bats `load` prefers `name.bash`."""
    return f"{HELPER_DIRECTORY}/{name}", f"{HELPER_DIRECTORY}/{name}.bash"


def _candidates_on_disk(name: str, present: set[str]) -> list[str]:
    """The files in `present` (a listing of `bats/helpers`) a reference to `name` can run. macOS
    paths ignore case, so a case variant of a candidate is that candidate."""
    folded = {candidate.casefold() for candidate in _helper_candidates(name)}
    return sorted(path for path in present if path.casefold() in folded)


def _helper_files(root: Path) -> set[str]:
    return _bounded_recursive_files(
        root,
        root / "bats" / "helpers",
        label="helper scan",
        include=lambda _name: True,
    )


def _helper_reference_errors(
    root: Path, relative: str, source: str, helper_pins: dict[str, str]
) -> list[str]:
    """A hosted file may run only helpers `helper_pins` pins: a referenced name needs a pinned
    candidate, and no candidate on disk may be unpinned. The names on disk come from a directory
    listing and are compared without case, since macOS paths ignore it, so a case variant of a
    candidate counts as one and must itself be pinned under its exact name. No other file there
    may extend the name, compared the same way, with a character a quoted reference can carry
    (`"$HELPERS/x.py y"` runs a file named `x.py y`, which a reader that removes quotes cannot tell
    from `x.py`)."""
    names, ambiguous = _helper_references(source)
    shown = _display_path(relative)
    unclosed = _first_unclosed_substitution(source)
    # The lines the unclosed line alone stops: the suffix's advice fixes only those.
    stopped = set(ambiguous) - set(_helper_references(source, sticky=False)[1])
    errors = [
        f"hosted file {shown} line {line_number} names the helper directory in a form the "
        'inventory cannot resolve (write "$HELPERS/<file name>" outside any substitution; the '
        "word helpers is refused anywhere else, comments included, and the line is read with "
        "quotes and backslashes removed, so helper's spells it too)"
        + (
            f"; line {unclosed} leaves a substitution open for the lines after it (it ends "
            "with a substitution opener, which blanks or a ( may follow, or holds an odd number "
            "of unescaped backticks), so no later line may name a helper: close it there and on "
            f"any later line that leaves one open, or name the helper above line {unclosed}"
            if unclosed is not None and line_number in stopped
            else ""
        )
        for line_number in ambiguous
    ]
    if not names:
        return errors
    try:
        present = _helper_files(root)
    except InventoryError as error:
        return errors + [str(error)]
    for name in sorted(names):
        candidates = _helper_candidates(name)
        on_disk = _candidates_on_disk(name, present)
        unpinned = [path for path in on_disk if path not in helper_pins]
        # A name needs a pinned candidate: its exact spelling, or the variant on disk.
        if not unpinned and not any(item in helper_pins for item in (*candidates, *on_disk)):
            unpinned = [candidates[0]]
        errors.extend(
            f"hosted file {shown} references helper {candidate}, which "
            f"TRUSTED_HOSTED_HELPER_SHA256 does not pin ({UPDATE_HINT})"
            for candidate in unpinned
        )
        prefix = candidates[0]
        if any(
            path.casefold().startswith(prefix.casefold())
            and len(path) > len(prefix)
            and not PLAIN_PATH_CHARACTER.match(path, len(prefix))
            for path in present
        ):
            errors.append(
                f"hosted file {shown} references helper {prefix}, and a file in "
                f"{HELPER_DIRECTORY} extends that name with a character outside "
                "[A-Za-z0-9_./-], which a quoted reference could run instead (rename that file)"
            )
    return errors


def _integer(value: Any, label: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        relation = "non-negative" if allow_zero else "positive"
        raise InventoryError(f"{label} must be a {relation} integer")
    return value


def _manifest_entries(manifest: dict[str, Any], tier: str) -> tuple[dict[str, Any], ...]:
    tiers = manifest.get("tiers")
    if not isinstance(tiers, dict) or set(tiers) != set(TIERS):
        raise InventoryError("inventory tiers must be exactly hosted and local")
    tier_manifest = tiers[tier]
    if not isinstance(tier_manifest, dict):
        raise InventoryError(f"{tier} tier inventory must be an object")
    if set(tier_manifest) != {"test_count", "files"}:
        raise InventoryError(f"{tier} tier inventory has unexpected fields")
    files = tier_manifest.get("files")
    if not isinstance(files, list) or not files:
        raise InventoryError(f"{tier} tier inventory files must be a non-empty array")
    if any(not isinstance(entry, dict) for entry in files):
        raise InventoryError(f"{tier} tier inventory entries must be objects")
    return tuple(files)


def _bounded_recursive_files(
    root: Path,
    scan_root: Path,
    *,
    label: str,
    include: Callable[[str], bool],
) -> set[str]:
    if not scan_root.is_dir() or scan_root.is_symlink():
        raise InventoryError(f"{label} root must be a directory")

    paths: list[str] = []
    stack: list[tuple[Path, int]] = [(scan_root, 0)]
    entry_count = 0
    file_count = 0
    aggregate_bytes = 0
    while stack:
        directory, depth = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    entry_count += 1
                    if entry_count > MAX_SCAN_ENTRIES:
                        raise InventoryError(f"{label} exceeds entry-count limit")
                    entry_depth = depth + 1
                    if entry_depth > MAX_SCAN_DEPTH:
                        raise InventoryError(f"{label} exceeds depth limit")
                    if entry.is_dir(follow_symlinks=False):
                        stack.append((Path(entry.path), entry_depth))
                        continue

                    file_count += 1
                    if file_count > MAX_SCAN_FILES:
                        raise InventoryError(f"{label} exceeds file-count limit")
                    metadata = entry.stat(follow_symlinks=False)
                    aggregate_bytes += metadata.st_size
                    if aggregate_bytes > MAX_SCAN_AGGREGATE_BYTES:
                        raise InventoryError(f"{label} exceeds aggregate-byte limit")
                    if include(entry.name):
                        paths.append(
                            Path(entry.path).relative_to(root).as_posix()
                        )
        except InventoryError:
            raise
        except OSError as error:
            raise InventoryError(f"{label} could not be enumerated") from error
    return set(paths)


def _scan_bats_files(root: Path) -> set[str]:
    return _bounded_recursive_files(
        root,
        root / "bats",
        label="Bats scan",
        include=lambda name: name.endswith(".bats"),
    )


def _validate_live(root: Path, manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    live = manifest.get("live")
    if not isinstance(live, dict):
        return ["live inventory must be an object"]
    if set(live) != {"test_count", "files"}:
        errors.append("live inventory has unexpected fields")
    try:
        if _integer(live.get("test_count"), "live test_count", allow_zero=True) != 0:
            errors.append("live test_count must remain zero")
    except InventoryError as error:
        errors.append(str(error))
    files = live.get("files")
    if not isinstance(files, list) or not all(isinstance(item, str) for item in files):
        return errors + ["live inventory files must be an array of paths"]
    if len(files) != len(set(files)):
        errors.append("live inventory contains a duplicate path")

    live_root = root / "bats" / "live"
    if live_root.is_symlink():
        return errors + ["live root is a symlink"]
    if live_root.is_dir():
        try:
            actual_files = _bounded_recursive_files(
                root,
                live_root,
                label="live scan",
                include=lambda _name: True,
            )
        except InventoryError as error:
            return errors + [str(error)]
    else:
        actual_files = set()
    expected_files = set(files)
    if actual_files != expected_files:
        errors.append("live inventory file-set drift")

    for relative in sorted(actual_files):
        path = root.joinpath(*PurePosixPath(relative).parts)
        if path.is_symlink():
            errors.append("live file is a symlink")
            continue
        try:
            source = _read_bounded_regular(
                path,
                label="live file",
                maximum=MAX_LIVE_FILE_BYTES,
            ).decode("utf-8")
        except (InventoryError, UnicodeError):
            errors.append("unable to read live file")
            continue
        try:
            _refuse_characters(source, "live file")
        except InventoryError as error:
            errors.append(str(error))
            continue
        if any(
            line.lstrip().startswith("@test")
            or ALTERNATE_TEST_DECLARATION.match(line.lstrip())
            for line in source.splitlines()
        ):
            errors.append("live file contains a Bats test declaration")
    return errors


def validate_repository(
    root: Path,
    manifest_path: Path,
    pins: Optional[tuple[dict[str, str], dict[str, str]]] = None,
) -> tuple[str, ...]:
    """Check `root` against `manifest_path`; `pins` (hosted-file map, helper map) replaces this
    script's TRUSTED_HOSTED_FILE_SHA256 and TRUSTED_HOSTED_HELPER_SHA256 for one call."""
    file_pins, helper_pins = (
        pins if pins is not None else (TRUSTED_HOSTED_FILE_SHA256, TRUSTED_HOSTED_HELPER_SHA256)
    )
    root = root.resolve()
    errors: list[str] = []
    try:
        manifest = load_manifest(manifest_path)
    except InventoryError as error:
        return (str(error),)

    if set(manifest) != {"schema_version", "test_count", "tiers", "live"}:
        errors.append("inventory manifest has unexpected fields")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must be {SCHEMA_VERSION}")

    expected_paths: set[str] = set()
    actual_total = 0
    for tier in TIERS:
        try:
            entries = _manifest_entries(manifest, tier)
            tier_manifest = manifest["tiers"][tier]
            declared_tier_count = _integer(
                tier_manifest.get("test_count"), f"{tier} test_count"
            )
        except InventoryError as error:
            errors.append(str(error))
            continue

        actual_tier_count = 0
        for entry in entries:
            try:
                if set(entry) != {
                    "path",
                    "test_count",
                    "ordered_title_sha256",
                    "file_sha256",
                }:
                    raise InventoryError(f"{tier} inventory entry has unexpected fields")
                relative = _relative_manifest_path(entry.get("path"), tier)
                if relative in expected_paths:
                    raise InventoryError("inventory contains a duplicate path")
                expected_paths.add(relative)
                declared_count = _integer(
                    entry.get("test_count"), "inventory file test_count"
                )
                identities = entry.get("ordered_title_sha256")
                if (
                    not isinstance(identities, list)
                    or len(identities) != declared_count
                    or any(not isinstance(item, str) or not DIGEST.fullmatch(item) for item in identities)
                ):
                    raise InventoryError("ordered title identities are malformed")
                file_identity = entry.get("file_sha256")
                if not isinstance(file_identity, str) or not DIGEST.fullmatch(file_identity):
                    raise InventoryError("file identity is malformed")
                path = _safe_file(root, relative)
                payload, source, titles = read_bats_file(path, relative)
                shown_entry = _display_path(relative)
                if len(titles) != declared_count:
                    errors.append(f"test-count drift in inventory file {shown_entry}")
                if _title_digests(titles) != tuple(identities):
                    errors.append(
                        f"ordered test-title identity drift in inventory file {shown_entry}"
                    )
                payload_identity = hashlib.sha256(payload).hexdigest()
                if payload_identity != file_identity:
                    errors.append(f"file content drift in inventory file {shown_entry}")
                if RESERVED_ROOT_ASSIGNMENT.search(source):
                    errors.append("inventory file overwrites reserved BATS_ROOT")
                source_lines = set(_lf_lines(source))
                if (
                    any(line not in source_lines for line in SHARED_ROOT_CONTRACT)
                    or STALE_NESTED_PATH.search(source)
                ):
                    errors.append("inventory file violates the shared-root contract")
                if tier == "hosted":
                    if LIVE_ONLY_HELPER_PATTERN.search(source):
                        errors.append("hosted file references live-only helper")
                    if (
                        file_pins.get(relative) != payload_identity
                        and _hosted_has_live_state_access(source)
                    ):
                        shown = _display_path(relative)
                        pin_state = (
                            "no longer matches its pin"
                            if relative in file_pins
                            else "is not pinned"
                        )
                        advice = UPDATE_HINT if shown == relative else RENAME_HINT
                        errors.append(
                            f"hosted file contains live-state access: {shown} {pin_state} in "
                            "TRUSTED_HOSTED_FILE_SHA256 (a test that reads live state belongs "
                            f"in the local tier; {advice})"
                        )
                    errors.extend(
                        _helper_reference_errors(root, relative, source, helper_pins)
                    )
                else:
                    errors.extend(_local_lifecycle_errors(source, relative))
                # Same-source consistency canary (NOT an independent oracle):
                # _discover_bats_count shares _parse_bats_source's tokenizer, so on
                # a well-formed file already parsed above this re-parse always
                # agrees with len(titles). It is retained as a regression guard that
                # the two entry points stay in sync if either is edited later; the
                # bats-binary subprocess oracle it replaced was dropped for CI
                # portability.
                try:
                    discovered_count = _discover_bats_count(path, relative)
                    if discovered_count != len(titles):
                        errors.append("Bats discovery test-count drift")
                except InventoryError as error:
                    errors.append(str(error))
                actual_tier_count += len(titles)
            except InventoryError as error:
                errors.append(str(error))

        if actual_tier_count != declared_tier_count:
            errors.append(f"{tier} tier test-count drift")
        actual_total += actual_tier_count

    try:
        actual_paths = _scan_bats_files(root)
        if actual_paths - expected_paths:
            errors.append("unexpected Bats test file")
        if expected_paths - actual_paths:
            errors.append("manifest Bats test file is missing")
    except InventoryError as error:
        errors.append(str(error))

    try:
        declared_total = _integer(manifest.get("test_count"), "manifest test_count")
        if actual_total != declared_total:
            errors.append("manifest test-count drift")
    except InventoryError as error:
        errors.append(str(error))

    errors.extend(_validate_live(root, manifest))
    errors.extend(_validate_trusted_hosted_helpers(root, helper_pins))
    return tuple(errors)


def _catalog_entries_by_path(
    manifest: dict[str, Any],
    tier: str,
) -> dict[str, dict[str, Any]]:
    return {
        entry["path"]: entry
        for entry in _manifest_entries(manifest, tier)
    }


def _is_ordered_subsequence(baseline: Iterable[str], candidate: Iterable[str]) -> bool:
    remaining = iter(candidate)
    return all(any(item == expected for item in remaining) for expected in baseline)


def _validate_trusted_catalog(
    policy_manifest: dict[str, Any],
    candidate_manifest: dict[str, Any],
) -> tuple[str, ...]:
    """Enforce base-owned classification; source heuristics are defense-in-depth only."""
    errors: list[str] = []
    policy_hosted = _catalog_entries_by_path(policy_manifest, "hosted")
    candidate_hosted = _catalog_entries_by_path(candidate_manifest, "hosted")
    for relative, policy_entry in policy_hosted.items():
        candidate_entry = candidate_hosted.get(relative)
        if (
            candidate_entry is None
            or candidate_entry["ordered_title_sha256"]
            != policy_entry["ordered_title_sha256"]
        ):
            errors.append("candidate violates trusted hosted catalog")
            continue
        if candidate_entry["file_sha256"] != policy_entry["file_sha256"]:
            errors.append("candidate changes trusted hosted file")
    if set(candidate_hosted) - set(policy_hosted):
        errors.append("candidate adds unapproved hosted tests")

    policy_local = _catalog_entries_by_path(policy_manifest, "local")
    candidate_local = _catalog_entries_by_path(candidate_manifest, "local")
    for relative, policy_entry in policy_local.items():
        candidate_entry = candidate_local.get(relative)
        if (
            candidate_entry is None
            or candidate_entry["ordered_title_sha256"]
            != policy_entry["ordered_title_sha256"]
        ):
            errors.append("candidate violates trusted local catalog")
            continue
        if candidate_entry["file_sha256"] != policy_entry["file_sha256"]:
            errors.append("candidate changes trusted local file")
    return tuple(errors)


def _validate_trusted_hosted_helpers(
    root: Path, helper_pins: Optional[dict[str, str]] = None
) -> tuple[str, ...]:
    errors: list[str] = []
    pins = TRUSTED_HOSTED_HELPER_SHA256 if helper_pins is None else helper_pins
    for relative, expected in pins.items():
        shown = _display_path(relative)
        try:
            path = _safe_file(root, relative)
            payload = _read_bounded_regular(
                path,
                label="hosted helper",
                maximum=MAX_BATS_BYTES,
            )
        except InventoryError:
            errors.append(
                f"hosted helper catalog drift: {shown} is missing or not a regular file "
                "(restore it, or remove its pin by hand in a reviewed change; "
                "--update-shas never removes a helper pin)"
            )
            continue
        if hashlib.sha256(payload).hexdigest() != expected:
            errors.append(
                f"hosted helper catalog drift: {shown} does not match its pin in "
                f"TRUSTED_HOSTED_HELPER_SHA256 ({UPDATE_HINT})"
            )
    return tuple(errors)


def validate_candidate_repository(
    policy_root: Path,
    policy_manifest_path: Path,
    candidate_root: Path,
    candidate_manifest_path: Path,
) -> tuple[str, ...]:
    policy_root = policy_root.resolve()
    candidate_root = candidate_root.resolve()
    if (
        policy_root == candidate_root
        and policy_manifest_path.resolve() == candidate_manifest_path.resolve()
    ):
        return validate_repository(candidate_root, candidate_manifest_path)

    policy_errors = validate_repository(policy_root, policy_manifest_path)
    candidate_errors = validate_repository(candidate_root, candidate_manifest_path)
    errors = [f"trusted policy inventory: {error}" for error in policy_errors]
    errors.extend(f"candidate inventory: {error}" for error in candidate_errors)
    if not errors:
        try:
            policy_manifest = load_manifest(policy_manifest_path)
            candidate_manifest = load_manifest(candidate_manifest_path)
            errors.extend(_validate_trusted_catalog(policy_manifest, candidate_manifest))
            errors.extend(_validate_trusted_hosted_helpers(candidate_root))
        except InventoryError as error:
            errors.append(str(error))
    # Here the base branch's copy of this script judges the candidate with its own pins, so the
    # re-pin advice in a drift message cannot help from inside the pull request.
    if any(UPDATE_HINT in error for error in errors):
        errors.append(PULL_REQUEST_PIN_NOTE)
    return tuple(errors)


def _pin_literal_pattern(name: str) -> re.Pattern[str]:
    return re.compile(
        r"(?m)^" + re.escape(name) + r' = \{\n((?:    "[^"\\\n]*": "[0-9a-f]{64}",\n)*)\}\n'
    )


def _pin_literal(text: str, name: str) -> tuple[re.Match[str], dict[str, str]]:
    """The one literal of `name` in the existing format, and its entries."""
    starts = re.findall(r"(?m)^" + re.escape(name) + r"(?![A-Za-z0-9_])", text)
    match = _pin_literal_pattern(name).search(text)
    if len(starts) != 1 or match is None:
        raise InventoryError(f"{name}: expected exactly one literal in the existing format")
    pins: dict[str, str] = {}
    for path, digest in re.findall(r'    "([^"\\\n]*)": "([0-9a-f]{64})",\n', match.group(1)):
        if path in pins:
            raise InventoryError(f"{name}: the literal pins a path twice")
        pins[path] = digest
    return match, pins


def _bound_names(node: ast.AST) -> tuple[str, ...]:
    """Every name `node` binds or deletes, so a pin map bound a second time in any form counts:
    an assignment, annotated or augmented assignment, walrus, loop, `with` or comprehension
    target at any depth (tuple targets included), a `del`, a definition, a function or lambda
    parameter, an import (a star import counts as binding every map), an `except` name or a
    pattern capture."""
    if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
        return (node.id,)
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return (node.name,)
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        if any(alias.name == "*" for alias in node.names):
            return PIN_MAP_NAMES  # a star import may bind any name
        return tuple((alias.asname or alias.name).split(".")[0] for alias in node.names)
    if isinstance(node, ast.ExceptHandler) and node.name:
        return (node.name,)
    if isinstance(node, ast.arg):
        return (node.arg,)
    # Pattern matching (Python 3.10+); the script itself still parses on older interpreters.
    captures = tuple(getattr(ast, kind) for kind in ("MatchAs", "MatchStar") if hasattr(ast, kind))
    if captures and isinstance(node, captures) and node.name:
        return (node.name,)
    if hasattr(ast, "MatchMapping") and isinstance(node, ast.MatchMapping) and node.rest:
        return (node.rest,)
    return ()


def _mutated_names(node: ast.AST) -> tuple[str, ...]:
    """The names a node may change in place or hand to code that can: an item assignment or
    deletion (`NAME[key] = ...`, `del NAME[key]`), any attribute of the name (`NAME.update(...)`,
    `NAME.__init__(...)`, `f = NAME.pop`), or the name passed to a call (`dict.update(NAME, ...)`,
    `operator.setitem(NAME, ...)`, `f(*NAME)`), each written directly on the name. The script
    itself only reads each map by its bare name."""
    if (
        isinstance(node, ast.Subscript)
        and isinstance(node.ctx, (ast.Store, ast.Del))
        and isinstance(node.value, ast.Name)
    ):
        return (node.value.id,)
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        return (node.value.id,)
    if isinstance(node, ast.Call):
        values = [*node.args, *(keyword.value for keyword in node.keywords)]
        values = [value.value if isinstance(value, ast.Starred) else value for value in values]
        return tuple(value.id for value in values if isinstance(value, ast.Name))
    return ()


def _verified_pin_literals(text: str) -> dict[str, tuple[re.Match[str], dict[str, str]]]:
    """Each pin map's one literal in the existing format and its entries, checked with `ast`:
    the script binds each name exactly once anywhere (`_bound_names`), never stores into it,
    takes an attribute of it or passes it to a call directly by name (`_mutated_names`), and that
    one binding is the module-level `NAME = {...}` statement whose source span the text match
    covers, so the rewrite replaces the value the script really uses. A change through an alias
    (`pins = NAME; pins[key] = ...`), an expression that yields the map (`(NAME or {}).clear()`,
    `[NAME][0][key] = ...`), `globals()`, `vars()` or `setattr` is beyond a static check; the
    review of the script's diff covers it."""
    literals = {name: _pin_literal(text, name) for name in PIN_MAP_NAMES}
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError) as error:
        raise InventoryError("inventory script is not valid Python") from error
    bindings = dict.fromkeys(PIN_MAP_NAMES, 0)
    mutated: set[str] = set()
    for node in ast.walk(tree):
        for bound in _bound_names(node):
            if bound in bindings:
                bindings[bound] += 1
        mutated.update(name for name in _mutated_names(node) if name in bindings)
    line_starts = [0, *(match.end() for match in re.finditer(r"\r\n|\r|\n", text))]

    def offset(line: int, column: int) -> int:
        # `ast` counts columns in UTF-8 bytes and breaks lines where Python's tokenizer does.
        start = line_starts[line - 1]
        end = line_starts[line] if line < len(line_starts) else len(text)
        return start + len(text[start:end].encode("utf-8")[:column].decode("utf-8"))

    for name, (match, pins) in literals.items():
        if bindings[name] != 1:
            raise InventoryError(
                f"{name}: expected exactly one assignment in the script, found {bindings[name]}"
            )
        if name in mutated:
            raise InventoryError(
                f"{name}: the script may change the map in place (an item assignment or "
                "deletion, an attribute of the map, or the map passed to a call), so the rewritten "
                "literal might not be what it uses"
            )
        statements = [
            statement
            for statement in tree.body
            if isinstance(statement, ast.Assign)
            and len(statement.targets) == 1
            and isinstance(statement.targets[0], ast.Name)
            and statement.targets[0].id == name
            and isinstance(statement.value, ast.Dict)
        ]
        if (
            len(statements) != 1
            or offset(statements[0].lineno, statements[0].col_offset) != match.start()
            or offset(statements[0].end_lineno, statements[0].end_col_offset) != match.end() - 1
            or ast.literal_eval(statements[0].value) != pins
        ):
            raise InventoryError(
                f"{name}: its one assignment is not the module-level literal the rewrite replaces"
            )
    return literals


def _render_pin_literal(name: str, pins: dict[str, str]) -> str:
    entries = "".join(f'    "{path}": "{pins[path]}",\n' for path in sorted(pins))
    return f"{name} = {{\n{entries}}}\n"


def _write_replacing(path: Path, payload: bytes) -> None:
    """Replace `path` by a uniquely named sibling written in full, keeping its mode. The sibling
    is removed if anything fails, and one left by a killed run never blocks a later run."""
    mode = stat.S_IMODE(os.stat(path).st_mode)
    descriptor, name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".update-shas", dir=str(path.parent)
    )
    temporary = Path(name)
    try:
        try:
            view = memoryview(payload)
            while view:
                view = view[os.write(descriptor, view) :]
            os.fchmod(descriptor, mode)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def update_trusted_shas(
    root: Path,
    manifest_path: Path,
    script_path: Path,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Recompute TRUSTED_HOSTED_FILE_SHA256 and TRUSTED_HOSTED_HELPER_SHA256 from the files under
    `root` and rewrite their two literals in `script_path`; returns (report, errors).

    TRUST MODEL: an authoring convenience, never an approval. `run` refuses `--update-shas` while
    `CI` or `GITHUB_ACTIONS` is in the environment at all (even empty), and unless the running
    script is `<--root>/scripts/ci/bats_inventory.py`, a regular file inside --root and not a
    symlink: this function rewrites `script_path` (under
    `run`, the running script), never --root's copy on its own, so a run from another checkout
    would leave one tree's pins in the other tree's script. The pins exist so that a reviewer, not
    this script, decides which hosted-file content may skip the live-state heuristic and which
    helper content the hosted runner may execute. A hosted-file pin exempts that exact content from
    the heuristic, and it matters only for a file the heuristic flags; every hosted file in the
    tree today is flagged (seven through the command substitutions they contain, such as the
    `$(swift build ...)` binary default, and `bounded_exec.bats`, which has none, through its
    CLI-operation reading: a line whose first word is `"$bounded"`, the argument after a multi-line
    `python3 -c` script, reads as a command run through a variable the heuristic cannot resolve),
    so every hosted pin is in force. This function pins whatever is on disk, so the diff it leaves
    in `script_path` is exactly what a reviewer must read, including whether a re-pinned hosted
    file reads live state (the report marks each pin that exempts its file). Who judges: in
    pull-request CI `quality.py` runs the base commit's copy of this script (its `--policy-root` is
    a worktree of the base), so the base's pins judge the candidate and a candidate cannot bless
    itself by regenerating them; a push to `main` is judged by the pushed copy with its own pins.
    `scripts/**` is listed in CODEOWNERS, but no ruleset requires code-owner review yet (D46's
    interim ruleset on `main` blocks only force-pushes and deletion), so on `main` the review of
    the diff is the only gate.

    SCOPE (how each map is regenerated):
    - TRUSTED_HOSTED_FILE_SHA256 is an exemption. It is re-derived from exactly the files the
      manifest lists as hosted, so the entry of a file no longer hosted is removed (dropping an
      exemption narrows nothing a check needs).
    - TRUSTED_HOSTED_HELPER_SHA256 is a restriction (a pinned helper must keep its content).
      Every existing entry is kept and re-pinned and every helper a hosted file references
      (`_helper_references`) is added. An entry is never removed: a missing pinned helper
      refuses, and a removal is a hand edit in a reviewed change. A pinned helper no hosted file
      references is reported, not refused: the lifecycle and Messages-database helpers are
      pinned on purpose for the local tier, and refusing would force their pins out.
    - It writes only when the tree passes `validate_repository` with the new pins, that is with
      the live-state heuristic waived for the pinned hosted content and every other check in
      force (so it never pins a hosted file another check rejects, and the manifest must already
      be current), and only when `_verified_pin_literals` accepts `script_path`; everything
      outside the two literals is left byte for byte.
    - The report and errors name repository paths only, never file contents or digests."""
    root = root.resolve()
    try:
        script_bytes = _read_bounded_regular(
            script_path, label="inventory script", maximum=MAX_BATS_BYTES
        )
        try:
            text = script_bytes.decode("utf-8")
        except UnicodeError as error:
            raise InventoryError("inventory script is not valid UTF-8") from error
        literals = _verified_pin_literals(text)
        old = {name: pins for name, (_match, pins) in literals.items()}
        manifest = load_manifest(manifest_path)
        hosted_paths = [
            _relative_manifest_path(entry.get("path"), "hosted")
            for entry in _manifest_entries(manifest, "hosted")
        ]
    except InventoryError as error:
        return (), (str(error),)

    errors: list[str] = []
    files: dict[str, str] = {}
    exempted: set[str] = set()
    referenced: dict[str, str] = {}
    for relative in hosted_paths:
        shown = _display_path(relative)
        if shown != relative:
            errors.append(f"hosted file {shown} cannot be pinned")
            continue
        try:
            payload, source, _titles = read_bats_file(_safe_file(root, relative), relative)
        except InventoryError as error:
            errors.append(f"hosted file {shown}: {error}")
            continue
        files[relative] = hashlib.sha256(payload).hexdigest()
        if _hosted_has_live_state_access(source):
            exempted.add(relative)
        # An ambiguous reference adds no name here; the validation below refuses it.
        for name in _helper_references(source)[0]:
            referenced.setdefault(name, relative)
    present: set[str] = set()
    if referenced:
        try:
            present = _helper_files(root)
        except InventoryError as error:
            errors.append(str(error))
    helper_paths = set(old["TRUSTED_HOSTED_HELPER_SHA256"])
    for name, relative in sorted(referenced.items()):
        candidates = _candidates_on_disk(name, present)
        if not candidates and not helper_paths.intersection(_helper_candidates(name)):
            errors.append(
                f"hosted file {_display_path(relative)} references helper "
                f"{HELPER_DIRECTORY}/{name}, which is not a file in {HELPER_DIRECTORY}"
            )
        helper_paths.update(candidates)
    helpers: dict[str, str] = {}
    for relative in sorted(helper_paths):
        shown = _display_path(relative)
        if shown != relative:
            errors.append(f"helper {shown} cannot be pinned")
            continue
        try:
            payload = _read_bounded_regular(
                _safe_file(root, relative), label="hosted helper", maximum=MAX_BATS_BYTES
            )
        except InventoryError:
            errors.append(
                f"helper {shown} is missing or not a regular file (restore it, or remove its "
                "pin by hand in a reviewed change; --update-shas never removes a helper pin)"
                if relative in old["TRUSTED_HOSTED_HELPER_SHA256"]
                else f"helper {shown} is not a regular file"
            )
            continue
        helpers[relative] = hashlib.sha256(payload).hexdigest()
    if errors:
        return (), tuple(errors)

    remaining = validate_repository(root, manifest_path, (files, helpers))
    if remaining:
        return (), (
            "the tree fails the inventory even with regenerated pins; fix these first (an "
            "edited Bats file needs its bats/tier-inventory.json entry brought up to date):",
            *remaining,
        )

    new = dict(zip(PIN_MAP_NAMES, (files, helpers)))
    updated = text
    # Last literal first, so the offsets of the earlier one still hold.
    for name, (match, _pins) in sorted(
        literals.items(), key=lambda item: item[1][0].start(), reverse=True
    ):
        updated = (
            updated[: match.start()] + _render_pin_literal(name, new[name]) + updated[match.end() :]
        )
    report: list[str] = []
    for name, label in zip(PIN_MAP_NAMES, ("hosted file", "helper")):
        before, after = old[name], new[name]
        kept = set(before) & set(after)
        for action, paths in (
            ("added", set(after) - set(before)),
            ("removed", set(before) - set(after)),
            ("re-pinned", {path for path in kept if before[path] != after[path]}),
        ):
            report.extend(
                f"- {label} {action}: {_display_path(path)}"
                + (
                    " (its pin exempts this content from the live-state heuristic)"
                    if label == "hosted file" and action != "removed" and path in exempted
                    else ""
                )
                for path in sorted(paths)
            )
    changed = len(report)
    reachable = {
        candidate.casefold() for name in referenced for candidate in _helper_candidates(name)
    }
    report.extend(
        f"- helper kept although no hosted file references it: {path}"
        for path in sorted(helpers)
        if path.casefold() not in reachable
    )
    try:
        shown_script = _display_path(script_path.resolve().relative_to(root).as_posix())
    except ValueError:
        shown_script = _display_path(script_path.name)
    if updated == text:
        report.append("No pin changed: both maps already match the files on disk.")
        return tuple(report), ()
    try:
        _write_replacing(script_path, updated.encode("utf-8"))
    except OSError:
        return (), (f"could not rewrite {shown_script}",)
    report.append(
        f"Rewrote the pin maps in {shown_script} ({changed} pin(s) changed); review the diff "
        "before committing: it is not an approval."
    )
    return tuple(report), ()


def parse_args(argv: list[str]) -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=repository_root)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--policy-root", type=Path)
    parser.add_argument("--policy-manifest", type=Path)
    parser.add_argument(
        "--update-shas",
        action="store_true",
        help=(
            "rewrite TRUSTED_HOSTED_FILE_SHA256 and TRUSTED_HOSTED_HELPER_SHA256 in this running "
            "script from the hosted files and helpers under --root; refused unless this script "
            "is --root's own scripts/ci/bats_inventory.py, and refused in CI (while CI or "
            "GITHUB_ACTIONS is set, even to an empty value). An authoring convenience whose "
            "diff must be reviewed, never an approval: run it from the repository root"
        ),
    )
    arguments = parser.parse_args(argv)
    if arguments.update_shas and (arguments.policy_root or arguments.policy_manifest):
        parser.error("--update-shas takes --root and --manifest only")
    return arguments


def run(argv: list[str]) -> int:
    arguments = parse_args(argv)
    root = arguments.root.resolve()
    manifest_path = arguments.manifest or root / "bats" / "tier-inventory.json"
    if arguments.update_shas:
        script = Path(__file__).resolve()
        try:
            # --root's own copy must be a regular file inside --root: through a symlink, the
            # rewrite would land in whatever file the link names.
            own_script: Optional[Path] = _safe_file(root, INVENTORY_SCRIPT).resolve()
        except InventoryError:
            own_script = None
        # Presence, not value: CI=false, CI=0 and CI= all refuse.
        if any(name in os.environ for name in CI_ENVIRONMENT_FLAGS):
            errors: tuple[str, ...] = (
                "it never runs in CI (CI or GITHUB_ACTIONS is set, even to an empty value); run "
                "it locally from the repository root and review the diff",
            )
        elif script != own_script:
            errors = (
                f"it rewrites the script it runs from, which must be {INVENTORY_SCRIPT} inside "
                "--root, a regular file and not a symlink; run that tree's own copy from its "
                "repository root",
            )
        else:
            report, errors = update_trusted_shas(root, manifest_path, script)
        if errors:
            print("Bats tier inventory --update-shas refused:", file=sys.stderr)
            for error in errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        print("Bats tier inventory --update-shas:")
        for line in report:
            print(line)
        return 0
    policy_root = (arguments.policy_root or root).resolve()
    policy_manifest_path = (
        arguments.policy_manifest
        or policy_root / "bats" / "tier-inventory.json"
    )
    errors = validate_candidate_repository(
        policy_root,
        policy_manifest_path,
        root,
        manifest_path,
    )
    if errors:
        print("Bats tier inventory failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    manifest = load_manifest(manifest_path)
    print(f"Bats tier inventory: {manifest['test_count']} tests verified")
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
