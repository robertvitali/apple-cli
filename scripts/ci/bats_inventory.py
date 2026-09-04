#!/usr/bin/env python3
"""Verify the versioned physical partition of Bats test tiers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
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
TRUSTED_HOSTED_FILE_SHA256 = {
    "bats/hosted/bounded_exec.bats": "13e4976b41a295182873e45c7f33c84dd7712e2ee16399fc6c0fe561056d4c26",
    "bats/hosted/calendar.bats": "78feed6a5cd530cc1a3f922c45f5ceb482db45fd36d00ee9fdfe816a87a9b6e4",
    "bats/hosted/contacts.bats": "54db1ad8c0c5ed029a200121e1aaff78422c272698db178ee4d013095c74a2b8",
    "bats/hosted/mail.bats": "9f75ec3194e5efde3b925c3fc9e42c247f26780961e3f5d6108393dca8d537ef",
    "bats/hosted/messages.bats": "23a087ee666d59ad74899ca98186feebd5b20f2db24b0804c5a5c456b8c5cf40",
    "bats/hosted/notes.bats": "e7b8342937711212df38cf9e0a636d63a69379d5baa11ca5b464cb0192b978a3",
    "bats/hosted/reminders.bats": "1b6c08b75acce52bc714e822c8cb652e8917e963eb18804b1a86e0fa95e6aa40",
    "bats/hosted/smoke.bats": "7bd533f47c3271ae141be9e4d95b93b5b476cd5bd68e46908d5a634cf53095e1",
}
TRUSTED_HOSTED_HELPER_SHA256 = {
    "bats/helpers/applescript_syntax_check.py": "40f56f5659dfb3bbc4c8b4b36d30ac12ad943f7c3fd78981800f3da46343e996",
    "bats/helpers/bounded_exec.py": "84260117f0505f2f2883fa2ec1b5fc5a577d4a05cc1ba268ae26e8948ab475c9",
    "bats/helpers/execute_envelope_lint.py": "430eba15fea468da6415441657087f7f2b70b0e6853ae70777c7b52a652454ba",
    "bats/helpers/md_tables_wellformed.py": "2ee916ec014906507474d7a63d89eb2538d277b628aedf404a87fbb448e4f49a",
    "bats/helpers/messages_db_probe.py": "da7daca3cf7fd967f3b00cea30724ea8b99411d6879458ee8caeb143ffc290e2",
    "bats/helpers/no_flagless_writes.py": "6c238da220f8c599afda95741a93142ab02febc6f35890100e7711d408534c39",
    "bats/helpers/queue_table_wellformed.py": "4adbf9c0eee8e15c12cb131177bd7fcda12edcd1e286d93eb2756525b6a60369",
    "bats/helpers/quoted_not_found.py": "ae039a574d4af4a22dd4ba83499639883b15a644a9f51ee61d66881c825beac5",
    "bats/helpers/subcommand_allowlist.py": "31f24f90a3a7865f7de99bdcab45170ab147bf0d477059969b92c3e34e93c6c2",
}


class InventoryError(ValueError):
    """Raised when inventory input is malformed."""


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
) -> Optional[str]:
    index = 0
    while index < len(line):
        character = line[index]
        if quote is not None:
            if character == quote:
                quote = None
            elif character == "\\" and quote != "'":
                index += 1
            index += 1
            continue

        if character in ("'", '"', "`"):
            quote = character
            index += 1
            continue
        if character == "\\":
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
            index = cursor
            continue
        index += 1
    return quote


def _parse_bats_source(source: str, relative: str) -> tuple[str, ...]:
    lines = source.splitlines()
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

    count = 0
    quote: Optional[str] = None
    heredocs: list[tuple[str, bool]] = []
    for line_number, line in enumerate(source.splitlines(), 1):
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
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    ]
    executable = re.sub(r"\\[ \t]*\n", " ", "\n".join(executable_lines))
    policy_source = "\n".join(
        line for line in executable.splitlines() if line not in SHARED_ROOT_CONTRACT
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
        if any(
            line.lstrip().startswith("@test")
            or ALTERNATE_TEST_DECLARATION.match(line.lstrip())
            for line in source.splitlines()
        ):
            errors.append("live file contains a Bats test declaration")
    return errors


def validate_repository(root: Path, manifest_path: Path) -> tuple[str, ...]:
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
                if len(titles) != declared_count:
                    errors.append("test-count drift in inventory file")
                if _title_digests(titles) != tuple(identities):
                    errors.append("ordered test-title identity drift in inventory file")
                payload_identity = hashlib.sha256(payload).hexdigest()
                if payload_identity != file_identity:
                    errors.append("file content drift in inventory file")
                if RESERVED_ROOT_ASSIGNMENT.search(source):
                    errors.append("inventory file overwrites reserved BATS_ROOT")
                source_lines = set(source.splitlines())
                if (
                    any(line not in source_lines for line in SHARED_ROOT_CONTRACT)
                    or STALE_NESTED_PATH.search(source)
                ):
                    errors.append("inventory file violates the shared-root contract")
                if tier == "hosted":
                    if LIVE_ONLY_HELPER_PATTERN.search(source):
                        errors.append("hosted file references live-only helper")
                    if (
                        TRUSTED_HOSTED_FILE_SHA256.get(relative) != payload_identity
                        and _hosted_has_live_state_access(source)
                    ):
                        errors.append("hosted file contains live-state access")
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
    errors.extend(_validate_trusted_hosted_helpers(root))
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


def _validate_trusted_hosted_helpers(root: Path) -> tuple[str, ...]:
    if not (root / "bats" / "helpers").exists():
        return ()
    errors: list[str] = []
    for relative, expected in TRUSTED_HOSTED_HELPER_SHA256.items():
        try:
            path = _safe_file(root, relative)
            payload = _read_bounded_regular(
                path,
                label="hosted helper",
                maximum=MAX_BATS_BYTES,
            )
        except InventoryError:
            errors.append("hosted helper catalog drift")
            continue
        if hashlib.sha256(payload).hexdigest() != expected:
            errors.append("hosted helper catalog drift")
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
    if errors:
        return tuple(errors)

    try:
        policy_manifest = load_manifest(policy_manifest_path)
        candidate_manifest = load_manifest(candidate_manifest_path)
        errors.extend(_validate_trusted_catalog(policy_manifest, candidate_manifest))
        errors.extend(_validate_trusted_hosted_helpers(candidate_root))
    except InventoryError as error:
        errors.append(str(error))
    return tuple(errors)


def parse_args(argv: list[str]) -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=repository_root)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--policy-root", type=Path)
    parser.add_argument("--policy-manifest", type=Path)
    return parser.parse_args(argv)


def run(argv: list[str]) -> int:
    arguments = parse_args(argv)
    root = arguments.root.resolve()
    manifest_path = arguments.manifest or root / "bats" / "tier-inventory.json"
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
