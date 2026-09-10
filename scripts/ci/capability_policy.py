#!/usr/bin/env python3
"""Validate exact-SHA command/argument capability and executed-test evidence."""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, FrozenSet, Iterator, NamedTuple, Optional, Set, Tuple
import xml.etree.ElementTree as ElementTree


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import bats_inventory
import capability_schema as schema


class PolicyError(ValueError):
    """Raised with a stable, value-free capability-policy diagnostic."""


class _ValueFreeArgumentParser(argparse.ArgumentParser):
    """Keep untrusted CLI values out of policy diagnostics."""

    def error(self, _message: str) -> None:
        raise PolicyError("cli-arguments-invalid")


class EvidenceRecord(NamedTuple):
    tier: str
    content_sha256: str
    runtime_id: Optional[str]


class CandidateDetails(NamedTuple):
    root: Path
    sha: str
    manifest: dict[str, Any]
    catalog: Dict[str, EvidenceRecord]
    report: dict[str, Any]


_COMMAND_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_SHA = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SWIFT_ID = re.compile(
    r"^swift:(?P<path>Tests/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.swift):"
    r"(?P<symbol>[A-Za-z_][A-Za-z0-9_]*):(?P<occurrence>[1-9][0-9]*)$"
)
_ORIGIN_ID = re.compile(r"^(?:port|extra):[a-z0-9][a-z0-9._-]*$")
_ORIGIN_ANCHOR = re.compile(
    r"<!-- capability-id: ((?:port|extra):[a-z0-9][a-z0-9._-]*) -->"
)
_EVIDENCE_ROLES = ("parser_help", "invalid_exit", "json_envelope", "behavior")
_HOSTED_ROLES = frozenset(("parser_help", "invalid_exit", "json_envelope"))
_COMMAND_REQUIRED_FIELDS = frozenset(
    ("abstract", "arguments", "commandName", "shouldDisplay")
)
_COMMAND_OPTIONAL_FIELDS = frozenset(
    ("aliases", "defaultSubcommand", "subcommands", "superCommands")
)
_ARGUMENT_REQUIRED_FIELDS = frozenset(
    (
        "isOptional",
        "isRepeating",
        "kind",
        "parsingStrategy",
        "shouldDisplay",
        "valueName",
    )
)
_ARGUMENT_OPTIONAL_FIELDS = frozenset(
    ("abstract", "defaultValue", "names", "preferredName")
)
_FRAMEWORK_HELP_COMMAND = {
    "abstract": "Show subcommand help information.",
    "arguments": [
        {
            "isOptional": True,
            "isRepeating": True,
            "kind": "positional",
            "parsingStrategy": "default",
            "shouldDisplay": True,
            "valueName": "subcommands",
        },
        {
            "isOptional": True,
            "isRepeating": False,
            "kind": "flag",
            "names": [
                {"kind": "short", "name": "h"},
                {"kind": "long", "name": "help"},
                {"kind": "longWithSingleDash", "name": "help"},
            ],
            "parsingStrategy": "default",
            "preferredName": {"kind": "long", "name": "help"},
            "shouldDisplay": False,
            "valueName": "help",
        },
        {
            "abstract": "Show the version.",
            "isOptional": True,
            "isRepeating": False,
            "kind": "flag",
            "names": [{"kind": "long", "name": "version"}],
            "parsingStrategy": "default",
            "preferredName": {"kind": "long", "name": "version"},
            "shouldDisplay": True,
            "valueName": "version",
        },
    ],
    "commandName": "help",
    "shouldDisplay": True,
    "superCommands": ["apple"],
}

MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_GIT_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_TREE_BYTES = 32 * 1024 * 1024
MAX_TREE_ENTRIES = 100_000
MAX_RUNNER_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_RUNTIME_ATTESTATION_BYTES = 32 * 1024 * 1024
MAX_RUNTIME_DUMP_BYTES = 16 * 1024 * 1024
MAX_XUNIT_BYTES = 32 * 1024 * 1024
MAX_BINARY_BYTES = 256 * 1024 * 1024
MAX_RUNTIME_SECONDS = 30 * 60
MAX_SOURCE_FILE_BYTES = 64 * 1024 * 1024
MAX_SOURCE_TREE_BYTES = 512 * 1024 * 1024
MAX_COMMANDS = 4096
MAX_ARGUMENTS = 20_000
MAX_SWIFT_FILES = 4096
MAX_SWIFT_TESTS = 20_000
MAX_SWIFT_BYTES = 128 * 1024 * 1024
MAX_BATS_FILES = 4096
MAX_BATS_TESTS = 20_000
MAX_BATS_BYTES = 128 * 1024 * 1024
MAX_MANUAL_FILES = 4096
MAX_MANUAL_BYTES = 128 * 1024 * 1024
MAX_ORIGIN_DOCUMENTS = 10_000
MAX_ORIGIN_DOCUMENT_BYTES = 64 * 1024 * 1024

MANIFEST_PATH = "docs/capabilities.json"
SWIFT_CATALOG_PATH = "Tests/capability-tests.json"
BATS_INVENTORY_PATH = "bats/tier-inventory.json"
RUNTIME_CONTRACT = "apple-cli-capability-runtime-v1"


def canonical_json(value: Any) -> str:
    """Return the canonical tracked representation used by this policy."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"


def _without_symlink_components(path: Path) -> Path:
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current = current / component
        try:
            if current.is_symlink():
                raise PolicyError("input-not-regular")
        except OSError as error:
            raise PolicyError("input-not-regular") from error
    return absolute


def _read_regular_bytes(path: Path, maximum: int = MAX_JSON_BYTES) -> bytes:
    absolute = _without_symlink_components(path)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    try:
        descriptor = os.open(str(absolute), flags)
    except OSError as error:
        raise PolicyError("input-not-regular") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PolicyError("input-not-regular")
        if metadata.st_size > maximum:
            raise PolicyError("input-too-large")
        chunks = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > maximum:
            raise PolicyError("input-too-large")
        if len(payload) != metadata.st_size:
            raise PolicyError("input-changed")
        return payload
    finally:
        os.close(descriptor)


def _load_json(path: Path, *, canonical: bool = False) -> Any:
    payload = _read_regular_bytes(path)
    try:
        value = schema.parse_json_bytes(payload)
    except schema.SchemaError as error:
        raise PolicyError(str(error)) from error
    if canonical and payload != canonical_json(value).encode("utf-8"):
        raise PolicyError("json-not-canonical")
    return value


def _run_bounded_command(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    timeout: float,
    maximum: int,
    failure: str,
    output_failure: str,
) -> bytes:
    process: Optional[subprocess.Popen[bytes]] = None
    completed = False
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            raise PolicyError(failure)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        stdout_chunks = []
        output_bytes = 0
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(process.args, timeout)
            ready = selector.select(remaining)
            if not ready:
                raise subprocess.TimeoutExpired(process.args, timeout)
            for key, _events in ready:
                chunk = os.read(
                    key.fd,
                    min(65536, max(1, maximum + 1 - output_bytes)),
                )
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output_bytes += len(chunk)
                if output_bytes > maximum:
                    raise PolicyError(output_failure)
                if key.data == "stdout":
                    stdout_chunks.append(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(process.args, timeout)
        if process.wait(timeout=remaining) != 0:
            raise PolicyError(failure)
        completed = True
        return b"".join(stdout_chunks)
    except PolicyError:
        raise
    except (OSError, subprocess.SubprocessError) as error:
        raise PolicyError(failure) from error
    finally:
        selector.close()
        if process is not None:
            if not completed:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    if process.poll() is None:
                        process.kill()
            try:
                process.wait(timeout=1)
            except subprocess.SubprocessError:
                pass
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()


def _git_environment() -> dict[str, str]:
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
    }


def _run_git_bytes(
    root: Path, *arguments: str, maximum: Optional[int] = None
) -> bytes:
    limit = MAX_GIT_OUTPUT_BYTES if maximum is None else maximum
    return _run_bounded_command(
        [
            "/usr/bin/git",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "credential.helper=",
            "-C",
            str(root),
            *arguments,
        ],
        cwd=root,
        environment=_git_environment(),
        timeout=10,
        maximum=limit,
        failure="checkout-invalid",
        output_failure="checkout-output-too-large",
    )


def _run_git(root: Path, *arguments: str) -> str:
    try:
        return _run_git_bytes(root, *arguments).decode("utf-8")
    except UnicodeDecodeError as error:
        raise PolicyError("checkout-invalid") from error


def _validate_checkout(root: Path, sha: str) -> Path:
    if not isinstance(sha, str) or _SHA.fullmatch(sha) is None:
        raise PolicyError("checkout-invalid")
    absolute = _without_symlink_components(root)
    try:
        resolved = absolute.resolve(strict=True)
        if not stat.S_ISDIR(resolved.stat().st_mode):
            raise PolicyError("checkout-invalid")
    except OSError as error:
        raise PolicyError("checkout-invalid") from error
    try:
        top = Path(_run_git(resolved, "rev-parse", "--show-toplevel").strip()).resolve(
            strict=True
        )
    except OSError as error:
        raise PolicyError("checkout-invalid") from error
    if top != resolved or _run_git(resolved, "rev-parse", "HEAD").strip() != sha:
        raise PolicyError("checkout-invalid")
    if _run_git(resolved, "status", "--porcelain=v1", "-z"):
        raise PolicyError("checkout-dirty")
    return resolved


class GitTreeEntry(NamedTuple):
    mode: str
    object_type: str
    oid: str


class CommitSnapshot:
    """One exact commit tree with each referenced blob captured at most once."""

    def __init__(
        self,
        root: Path,
        sha: str,
        tree_oid: str,
        entries: Dict[str, GitTreeEntry],
    ) -> None:
        self.root = root
        self.sha = sha
        self.tree_oid = tree_oid
        self.entries = entries
        self._blobs: Dict[str, bytes] = {}

    @classmethod
    def capture(cls, root: Path, sha: str) -> "CommitSnapshot":
        try:
            tree_oid = _run_git(root, "rev-parse", f"{sha}^{{tree}}").strip()
        except PolicyError:
            raise
        if _SHA.fullmatch(tree_oid) is None:
            raise PolicyError("commit-tree-invalid")
        payload = _run_git_bytes(
            root,
            "ls-tree",
            "-r",
            "-z",
            "--full-tree",
            sha,
            maximum=MAX_TREE_BYTES,
        )
        entries: Dict[str, GitTreeEntry] = {}
        records = payload.split(b"\0")
        if records[-1:] != [b""]:
            raise PolicyError("commit-tree-invalid")
        for record in records[:-1]:
            try:
                metadata, raw_path = record.split(b"\t", 1)
                mode, object_type, oid = metadata.decode("ascii").split(" ")
                path = raw_path.decode("utf-8")
            except (UnicodeDecodeError, ValueError) as error:
                raise PolicyError("commit-tree-invalid") from error
            if (
                len(entries) >= MAX_TREE_ENTRIES
                or path in entries
                or not path
                or len(path) > 512
                or any(ord(character) < 32 or ord(character) == 127 for character in path)
                or _SHA.fullmatch(oid) is None
            ):
                raise PolicyError("commit-tree-invalid")
            pure = PurePosixPath(path)
            if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
                raise PolicyError("commit-tree-invalid")
            entries[path] = GitTreeEntry(mode, object_type, oid)
        return cls(root, sha, tree_oid, entries)

    def blob(self, raw: Any, *, maximum: int = MAX_TEXT_BYTES) -> bytes:
        path = _repository_relative(raw)
        entry = self.entries.get(path)
        if (
            entry is None
            or entry.object_type != "blob"
            or entry.mode not in {"100644", "100755"}
        ):
            raise PolicyError("commit-blob-invalid")
        cached = self._blobs.get(path)
        if cached is not None:
            if len(cached) > maximum:
                raise PolicyError("input-too-large")
            return cached
        payload = _run_git_bytes(
            self.root,
            "cat-file",
            "blob",
            entry.oid,
            maximum=maximum,
        )
        if len(payload) > maximum:
            raise PolicyError("input-too-large")
        header = f"blob {len(payload)}\0".encode("ascii")
        if hashlib.sha1(header + payload).hexdigest() != entry.oid:
            raise PolicyError("commit-blob-invalid")
        self._blobs[path] = payload
        return payload

    def matching_paths(self, prefix: str, suffix: str) -> list[str]:
        prefix_with_separator = prefix.rstrip("/") + "/"
        return sorted(
            path
            for path in self.entries
            if path.startswith(prefix_with_separator) and path.endswith(suffix)
        )


@contextmanager
def _materialized_snapshot(snapshot: CommitSnapshot) -> Iterator[Path]:
    """Materialize only regular exact-tree blobs into a private build root."""
    with tempfile.TemporaryDirectory(prefix="apple-cli-capability-source-") as directory:
        source_root = Path(directory).resolve() / "source"
        source_root.mkdir(mode=0o700)
        total_bytes = 0
        for path in sorted(snapshot.entries):
            entry = snapshot.entries[path]
            if entry.object_type != "blob" or entry.mode not in {"100644", "100755"}:
                raise PolicyError("commit-tree-nonregular")
            payload = snapshot.blob(path, maximum=MAX_SOURCE_FILE_BYTES)
            total_bytes += len(payload)
            if total_bytes > MAX_SOURCE_TREE_BYTES:
                raise PolicyError("commit-tree-content-too-large")
            destination = source_root.joinpath(*PurePosixPath(path).parts)
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            try:
                descriptor = os.open(str(destination), flags, 0o600)
            except OSError as error:
                raise PolicyError("commit-tree-materialization-failed") from error
            try:
                offset = 0
                while offset < len(payload):
                    written = os.write(descriptor, payload[offset:])
                    if written <= 0:
                        raise PolicyError("commit-tree-materialization-failed")
                    offset += written
                os.fchmod(descriptor, 0o755 if entry.mode == "100755" else 0o644)
            except OSError as error:
                raise PolicyError("commit-tree-materialization-failed") from error
            finally:
                os.close(descriptor)
        yield source_root


def _repository_relative(
    raw: Any,
    *,
    prefix: Tuple[str, ...] = (),
    suffix: str = "",
) -> str:
    if not isinstance(raw, str) or not raw or len(raw) > 512:
        raise PolicyError("path-invalid")
    pure = PurePosixPath(raw)
    if (
        pure.is_absolute()
        or any(part in ("", ".", "..") for part in pure.parts)
        or (prefix and pure.parts[: len(prefix)] != prefix)
        or (suffix and pure.suffix != suffix)
    ):
        raise PolicyError("path-invalid")
    return pure.as_posix()


def _blob_json(
    snapshot: CommitSnapshot,
    path: str,
    *,
    canonical: bool,
) -> Any:
    payload = snapshot.blob(path, maximum=MAX_JSON_BYTES)
    try:
        value = schema.parse_json_bytes(payload)
    except schema.SchemaError as error:
        raise PolicyError(str(error)) from error
    if canonical and payload != canonical_json(value).encode("utf-8"):
        raise PolicyError("json-not-canonical")
    return value


def _relative_path(root: Path, raw: Any, *, prefix: Tuple[str, ...], suffix: str) -> Path:
    if not isinstance(raw, str) or not raw or len(raw) > 512:
        raise PolicyError("path-invalid")
    pure = PurePosixPath(raw)
    if (
        pure.is_absolute()
        or any(part in ("", ".", "..") for part in pure.parts)
        or pure.parts[: len(prefix)] != prefix
        or pure.suffix != suffix
    ):
        raise PolicyError("path-invalid")
    candidate = root.joinpath(*pure.parts)
    try:
        candidate.resolve(strict=True).relative_to(root)
    except (OSError, ValueError) as error:
        raise PolicyError("path-invalid") from error
    _without_symlink_components(candidate)
    return candidate


def _source_bytes(
    source: Any,
    raw: Any,
    *,
    prefix: Tuple[str, ...],
    suffix: str,
) -> bytes:
    if isinstance(source, CommitSnapshot):
        path = _repository_relative(raw, prefix=prefix, suffix=suffix)
        return source.blob(path, maximum=MAX_TEXT_BYTES)
    path = _relative_path(Path(source), raw, prefix=prefix, suffix=suffix)
    return _read_regular_bytes(path, MAX_TEXT_BYTES)


def _source_text(
    source: Any,
    raw: Any,
    *,
    prefix: Tuple[str, ...],
    suffix: str,
) -> str:
    try:
        return _source_bytes(
            source,
            raw,
            prefix=prefix,
            suffix=suffix,
        ).decode("utf-8")
    except UnicodeDecodeError as error:
        raise PolicyError("text-invalid") from error


def _display_name(name: dict[str, Any]) -> str:
    kind = name.get("kind")
    if not isinstance(kind, str):
        raise PolicyError("dump-argument-name-invalid")
    prefix = {"long": "--", "short": "-", "longWithSingleDash": "-"}.get(kind)
    raw = name.get("name")
    if prefix is None or not isinstance(raw, str) or not raw:
        raise PolicyError("dump-argument-name-invalid")
    return prefix + raw


def _argument_structure(argument: dict[str, Any]) -> dict[str, Any]:
    structure = {
        "abstract": argument.get("abstract", ""),
        "default_present": "defaultValue" in argument,
        "default_value": argument.get("defaultValue"),
        "is_optional": argument.get("isOptional"),
        "is_repeating": argument.get("isRepeating"),
        "kind": argument.get("kind"),
        "names": argument.get("names", []),
        "parsing_strategy": argument.get("parsingStrategy"),
        "preferred_name": argument.get("preferredName"),
        "value_name": argument.get("valueName"),
    }
    return structure


def _validate_argument(argument: dict[str, Any]) -> None:
    if (
        type(argument.get("isOptional")) is not bool
        or type(argument.get("isRepeating")) is not bool
        or not isinstance(argument.get("kind"), str)
        or argument.get("kind") not in {"flag", "option", "positional"}
        or not isinstance(argument.get("parsingStrategy"), str)
        or argument.get("parsingStrategy") not in {"default", "upToNextOption"}
        or argument.get("shouldDisplay") is not True
        or not isinstance(argument.get("valueName"), str)
        or not argument["valueName"]
        or ("abstract" in argument and not isinstance(argument["abstract"], str))
        or ("defaultValue" in argument and not isinstance(argument["defaultValue"], str))
    ):
        raise PolicyError("dump-argument-shape-invalid")
    kind = argument["kind"]
    names = argument.get("names")
    preferred = argument.get("preferredName")
    if kind == "positional":
        if names is not None or preferred is not None:
            raise PolicyError("dump-argument-shape-invalid")
        return
    if not isinstance(names, list) or not names or not isinstance(preferred, dict):
        raise PolicyError("dump-argument-shape-invalid")
    normalized = []
    for name in names:
        if (
            not isinstance(name, dict)
            or set(name) != {"kind", "name"}
            or not isinstance(name.get("kind"), str)
            or name.get("kind") not in {"long", "short", "longWithSingleDash"}
            or not isinstance(name.get("name"), str)
            or not name["name"]
        ):
            raise PolicyError("dump-argument-shape-invalid")
        normalized.append((name["kind"], name["name"]))
    if len(normalized) != len(set(normalized)) or (
        preferred.get("kind"), preferred.get("name")
    ) not in normalized:
        raise PolicyError("dump-argument-shape-invalid")


def _argument_id(command_id: str, argument: dict[str, Any], ordinal: int) -> str:
    kind = argument.get("kind")
    preferred = argument.get("preferredName")
    if kind == "positional":
        value_name = argument.get("valueName")
        if not isinstance(value_name, str) or not value_name:
            raise PolicyError("dump-argument-shape-invalid")
        return f"{command_id}::positional::{ordinal}:{value_name}"
    if not isinstance(preferred, dict):
        raise PolicyError("dump-argument-shape-invalid")
    return f"{command_id}::{kind}::{_display_name(preferred)}"


def _manual_path(path: list[str]) -> str:
    suffix = path[1:]
    if not suffix:
        return "docs/manual/index.md"
    return PurePosixPath("docs", "manual", *suffix).with_suffix(".md").as_posix()


def snapshot_manifest(dump: Any) -> dict[str, Any]:
    """Derive a canonical, deliberately incomplete command/argument skeleton."""
    if not isinstance(dump, dict) or set(dump) != {"command", "serializationVersion"}:
        if isinstance(dump, dict):
            raise PolicyError("dump-root-fields")
        raise PolicyError("dump-root-invalid")
    root = dump.get("command")
    if (
        type(dump.get("serializationVersion")) is not int
        or dump["serializationVersion"] != 0
        or not isinstance(root, dict)
    ):
        raise PolicyError("dump-root-invalid")

    commands: list[dict[str, Any]] = []
    arguments: list[dict[str, Any]] = []
    argument_ids: Set[str] = set()
    framework_help_seen = False

    def walk(command: dict[str, Any], path: list[str]) -> None:
        nonlocal framework_help_seen
        command_fields = set(command)
        if (
            not _COMMAND_REQUIRED_FIELDS.issubset(command_fields)
            or not command_fields.issubset(
                _COMMAND_REQUIRED_FIELDS | _COMMAND_OPTIONAL_FIELDS
            )
        ):
            raise PolicyError("dump-command-fields")
        name = command.get("commandName")
        if not isinstance(name, str) or not _COMMAND_NAME.fullmatch(name):
            raise PolicyError("dump-command-name-invalid")
        if (
            not isinstance(command.get("abstract"), str)
            or not isinstance(command.get("arguments"), list)
            or type(command.get("shouldDisplay")) is not bool
            or (
                "defaultSubcommand" in command
                and (
                    not isinstance(command["defaultSubcommand"], str)
                    or _COMMAND_NAME.fullmatch(command["defaultSubcommand"]) is None
                )
            )
        ):
            raise PolicyError("dump-command-shape-invalid")
        aliases = command.get("aliases", [])
        if (
            not isinstance(aliases, list)
            or any(
                not isinstance(alias, str) or _COMMAND_NAME.fullmatch(alias) is None
                for alias in aliases
            )
            or len(aliases) != len(set(aliases))
            or name in aliases
        ):
            raise PolicyError("dump-command-shape-invalid")
        current = path + [name]
        if len(current) > 16:
            raise PolicyError("dump-command-depth")
        if path:
            if command.get("superCommands") != path:
                raise PolicyError("dump-supercommands-invalid")
        elif "superCommands" in command:
            raise PolicyError("dump-supercommands-invalid")
        if current == ["apple", "help"]:
            if command != _FRAMEWORK_HELP_COMMAND:
                raise PolicyError("dump-framework-help-invalid")
            framework_help_seen = True
            return
        if command.get("shouldDisplay") is not True:
            raise PolicyError("dump-hidden-surface")
        command_id = " ".join(current)
        commands.append(
            {
                "abstract": command.get("abstract", ""),
                "aliases": aliases,
                "default_child": command.get("defaultSubcommand"),
                "evidence": {
                    "behavior": [],
                    "invalid_exit": [],
                    "json_envelope": [],
                    "parser_help": [],
                },
                "id": command_id,
                "manual": {"path": _manual_path(current), "tokens": [command_id]},
                "name": name,
                "origin_id": "",
                "path": current,
            }
        )
        if len(commands) > MAX_COMMANDS:
            raise PolicyError("dump-command-count")
        positional_ordinal = 0
        for argument in command.get("arguments", []):
            if not isinstance(argument, dict):
                raise PolicyError("dump-argument-shape-invalid")
            argument_fields = set(argument)
            if (
                not _ARGUMENT_REQUIRED_FIELDS.issubset(argument_fields)
                or not argument_fields.issubset(
                    _ARGUMENT_REQUIRED_FIELDS | _ARGUMENT_OPTIONAL_FIELDS
                )
            ):
                raise PolicyError("dump-argument-fields")
            _validate_argument(argument)
            if argument.get("kind") == "positional":
                positional_ordinal += 1
                ordinal: Optional[int] = positional_ordinal
                expected_token = str(argument.get("valueName", ""))
            else:
                ordinal = None
                preferred = argument.get("preferredName")
                expected_token = _display_name(preferred) if isinstance(preferred, dict) else ""
            argument_record = {
                "command_id": command_id,
                "evidence": {
                    "behavior": [],
                    "invalid_exit": [],
                    "json_envelope": [],
                    "parser_help": [],
                },
                "id": _argument_id(command_id, argument, positional_ordinal),
                "manual_tokens": [expected_token] if expected_token else [],
                "origin_id": "",
                "position_ordinal": ordinal,
                "structure": _argument_structure(argument),
            }
            if argument_record["id"] in argument_ids:
                raise PolicyError("dump-argument-collision")
            argument_ids.add(argument_record["id"])
            arguments.append(argument_record)
            if len(arguments) > MAX_ARGUMENTS:
                raise PolicyError("dump-argument-count")
        children = command.get("subcommands", [])
        if not isinstance(children, list):
            raise PolicyError("dump-command-shape-invalid")
        sibling_tokens: Set[str] = set()
        for child in children:
            if not isinstance(child, dict):
                raise PolicyError("dump-command-shape-invalid")
            child_name = child.get("commandName")
            child_aliases = child.get("aliases", [])
            if (
                not isinstance(child_name, str)
                or not isinstance(child_aliases, list)
                or any(
                    not isinstance(alias, str) or _COMMAND_NAME.fullmatch(alias) is None
                    for alias in child_aliases
                )
                or len(child_aliases) != len(set(child_aliases))
            ):
                raise PolicyError("dump-command-shape-invalid")
            tokens = [child_name, *child_aliases]
            if len(tokens) != len(set(tokens)) or any(token in sibling_tokens for token in tokens):
                raise PolicyError("dump-command-collision")
            sibling_tokens.update(tokens)
        default_child = command.get("defaultSubcommand")
        child_names = {
            child.get("commandName") for child in children if isinstance(child, dict)
        }
        if default_child is not None and default_child not in child_names:
            raise PolicyError("dump-default-child-invalid")
        for child in children:
            walk(child, current)

    if root.get("commandName") != "apple":
        raise PolicyError("dump-root-command-invalid")
    walk(root, [])
    if not framework_help_seen:
        raise PolicyError("dump-framework-help-missing")
    commands.sort(key=lambda item: item["id"])
    arguments.sort(key=lambda item: item["id"])
    return {
        "arguments": arguments,
        "commands": commands,
        "contract_stage": schema.CONTRACT_STAGE,
        "counts": {
            "arguments": len(arguments),
            "commands": len(commands),
            "origins": 0,
        },
        "future_contracts": {
            "output_fields": [],
            "validation_surfaces": [],
        },
        "origins": [],
        "schema_version": schema.SCHEMA_VERSION,
        "status": "draft",
        "supersedes": [],
    }


def _swift_code_mask(source: str) -> str:
    """Mask comments and string contents while preserving source offsets."""
    masked = list(source)
    index = 0
    block_depth = 0
    length = len(source)
    while index < length:
        if block_depth:
            if source.startswith("/*", index):
                masked[index:index + 2] = "  "
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                masked[index:index + 2] = "  "
                block_depth -= 1
                index += 2
            else:
                if source[index] not in "\r\n":
                    masked[index] = " "
                index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end < 0 else end
            for offset in range(index, end):
                if source[offset] != "\r":
                    masked[offset] = " "
            index = end
            continue
        if source.startswith("/*", index):
            masked[index:index + 2] = "  "
            block_depth = 1
            index += 2
            continue
        quote_index = index
        hashes = 0
        while quote_index < length and source[quote_index] == "#":
            hashes += 1
            quote_index += 1
        if quote_index < length and source[quote_index] == '"':
            triple = source.startswith('"""', quote_index)
            opener_length = hashes + (3 if triple else 1)
            delimiter = ('"""' if triple else '"') + ("#" * hashes)
            for offset in range(index, min(length, index + opener_length)):
                masked[offset] = " "
            cursor = index + opener_length
            while cursor < length:
                if source.startswith(delimiter, cursor):
                    for offset in range(cursor, cursor + len(delimiter)):
                        masked[offset] = " "
                    cursor += len(delimiter)
                    break
                if hashes == 0 and source[cursor] == "\\":
                    masked[cursor] = " "
                    cursor += 1
                    if cursor < length:
                        if source[cursor] not in "\r\n":
                            masked[cursor] = " "
                        cursor += 1
                    continue
                if source[cursor] not in "\r\n":
                    masked[cursor] = " "
                cursor += 1
            else:
                raise PolicyError("test-catalog-source-invalid")
            index = cursor
            continue
        index += 1
    if block_depth:
        raise PolicyError("test-catalog-source-invalid")
    return "".join(masked)


def _swift_function_tests(source: str) -> Dict[str, list[bool]]:
    masked = _swift_code_mask(source)
    markers = [
        match.start() for match in re.finditer(r"(?m)^[ \t]*@Test\b", masked)
    ]
    functions = list(
        re.finditer(r"\bfunc[ \t]+([A-Za-z_][A-Za-z0-9_]*)\b", masked)
    )
    results: Dict[str, list[bool]] = {}
    marker_index = 0
    last_marker = -1
    previous_function = -1
    for function in functions:
        while marker_index < len(markers) and markers[marker_index] < function.start():
            last_marker = markers[marker_index]
            marker_index += 1
        is_test = (
            last_marker > previous_function
            and last_marker >= max(0, function.start() - 4096)
        )
        results.setdefault(function.group(1), []).append(is_test)
        previous_function = function.start()
    return results


def _swift_catalog(
    source_root: Any,
    raw: Any,
    passed_runtime_ids: Optional[FrozenSet[str]] = None,
) -> Dict[str, EvidenceRecord]:
    if not isinstance(raw, dict) or set(raw) != {"schema_version", "tests"}:
        raise PolicyError("test-catalog-invalid")
    if (
        type(raw["schema_version"]) is not int
        or raw["schema_version"] != 1
        or not isinstance(raw["tests"], list)
    ):
        raise PolicyError("test-catalog-invalid")
    if len(raw["tests"]) > MAX_SWIFT_TESTS:
        raise PolicyError("swift-catalog-too-large")
    records: Dict[str, EvidenceRecord] = {}
    runtime_ids: Set[str] = set()
    files: Dict[str, Tuple[bytes, Dict[str, list[bool]]]] = {}
    total_bytes = 0
    for item in raw["tests"]:
        if not isinstance(item, dict) or set(item) != {
            "file_sha256",
            "id",
            "occurrence",
            "path",
            "runtime_id",
            "symbol",
            "tier",
        }:
            raise PolicyError("test-catalog-invalid")
        identifier = item["id"]
        match = _SWIFT_ID.fullmatch(identifier) if isinstance(identifier, str) else None
        if (
            match is None
            or match.group("path") != item["path"]
            or match.group("symbol") != item["symbol"]
            or type(item["occurrence"]) is not int
            or item["occurrence"] < 1
            or int(match.group("occurrence")) != item["occurrence"]
            or item["tier"] != "logic"
            or not _valid_runtime_id(item["runtime_id"])
            or item["runtime_id"] in runtime_ids
            or not isinstance(item["file_sha256"], str)
            or _SHA256.fullmatch(item["file_sha256"]) is None
            or identifier in records
        ):
            raise PolicyError("test-catalog-invalid")
        if not _runtime_id_matches_symbol(item["runtime_id"], item["symbol"]):
            raise PolicyError("test-catalog-runtime-mismatch")
        path = _repository_relative(
            item["path"], prefix=("Tests",), suffix=".swift"
        )
        cached = files.get(path)
        if cached is None:
            if len(files) >= MAX_SWIFT_FILES:
                raise PolicyError("swift-catalog-too-large")
            payload = _source_bytes(
                source_root,
                path,
                prefix=("Tests",),
                suffix=".swift",
            )
            total_bytes += len(payload)
            if total_bytes > MAX_SWIFT_BYTES:
                raise PolicyError("swift-catalog-too-large")
            try:
                source = payload.decode("utf-8")
            except UnicodeDecodeError as error:
                raise PolicyError("test-catalog-invalid") from error
            cached = (payload, _swift_function_tests(source))
            files[path] = cached
        payload, function_tests = cached
        if hashlib.sha256(payload).hexdigest() != item["file_sha256"]:
            raise PolicyError("test-catalog-drift")
        symbol_matches = function_tests.get(item["symbol"], [])
        if len(symbol_matches) < item["occurrence"]:
            raise PolicyError("test-catalog-symbol-missing")
        if not symbol_matches[item["occurrence"] - 1]:
            raise PolicyError("test-catalog-symbol-not-test")
        if (
            passed_runtime_ids is not None
            and item["runtime_id"] not in passed_runtime_ids
        ):
            raise PolicyError("swift-evidence-unexecuted")
        records[identifier] = EvidenceRecord(
            "logic", item["file_sha256"], item["runtime_id"]
        )
        runtime_ids.add(item["runtime_id"])
    if not records:
        raise PolicyError("test-catalog-invalid")
    return records


def _bats_catalog(source_root: Any, raw: Any) -> Dict[str, EvidenceRecord]:
    if not isinstance(raw, dict) or set(raw) != {
        "live",
        "schema_version",
        "test_count",
        "tiers",
    }:
        raise PolicyError("bats-inventory-invalid")
    if (
        type(raw["schema_version"]) is not int
        or raw["schema_version"] != 1
        or not isinstance(raw["tiers"], dict)
        or type(raw.get("test_count")) is not int
    ):
        raise PolicyError("bats-inventory-invalid")
    if raw["test_count"] > MAX_BATS_TESTS:
        raise PolicyError("bats-catalog-too-large")
    if set(raw["tiers"]) != {"hosted", "local"}:
        raise PolicyError("bats-inventory-invalid")
    references: Dict[str, EvidenceRecord] = {}
    seen_files: Set[str] = set()
    total_bytes = 0
    total = 0
    for tier in ("hosted", "local"):
        tier_data = raw["tiers"][tier]
        if not isinstance(tier_data, dict) or set(tier_data) != {"files", "test_count"}:
            raise PolicyError("bats-inventory-invalid")
        files = tier_data["files"]
        if not isinstance(files, list) or type(tier_data["test_count"]) is not int:
            raise PolicyError("bats-inventory-invalid")
        ordered_paths = []
        for entry in files:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                raise PolicyError("bats-inventory-invalid")
            ordered_paths.append(entry["path"])
        if ordered_paths != sorted(ordered_paths):
            raise PolicyError("bats-inventory-invalid")
        tier_count = 0
        for entry in files:
            if not isinstance(entry, dict) or set(entry) != {
                "file_sha256",
                "ordered_title_sha256",
                "path",
                "test_count",
            }:
                raise PolicyError("bats-inventory-invalid")
            path = entry["path"]
            titles = entry["ordered_title_sha256"]
            if (
                not isinstance(path, str)
                or not isinstance(titles, list)
                or not titles
                or any(not isinstance(value, str) for value in titles)
                or len(titles) != len(set(titles))
                or type(entry["test_count"]) is not int
                or entry["test_count"] != len(titles)
                or not isinstance(entry["file_sha256"], str)
                or _SHA256.fullmatch(entry["file_sha256"]) is None
                or any(_SHA256.fullmatch(value) is None for value in titles)
            ):
                raise PolicyError("bats-inventory-invalid")
            expected_prefix = ("bats", tier)
            path = _repository_relative(
                path, prefix=expected_prefix, suffix=".bats"
            )
            if path in seen_files:
                raise PolicyError("bats-inventory-invalid")
            if len(seen_files) >= MAX_BATS_FILES:
                raise PolicyError("bats-catalog-too-large")
            payload = _source_bytes(
                source_root,
                path,
                prefix=expected_prefix,
                suffix=".bats",
            )
            seen_files.add(path)
            total_bytes += len(payload)
            if total_bytes > MAX_BATS_BYTES:
                raise PolicyError("bats-catalog-too-large")
            if hashlib.sha256(payload).hexdigest() != entry["file_sha256"]:
                raise PolicyError("bats-inventory-drift")
            try:
                source = payload.decode("utf-8")
            except UnicodeDecodeError as error:
                raise PolicyError("bats-inventory-invalid") from error
            # Reuse bats_inventory's heredoc/quote-aware parser as the single
            # source of truth for Bats title extraction. A bare per-line regex
            # here mis-parsed a `@test "..." {`-shaped line inside a heredoc body
            # as a real declaration, diverging from bats_inventory and producing a
            # spurious title-drift. Map the parser's errors onto this module's
            # taxonomy, preserving prior behavior: a malformed declaration stays
            # "declaration-invalid", and a file with no tests still falls through
            # to the drift comparison below.
            try:
                parsed_titles = bats_inventory._parse_bats_source(source, path)
            except bats_inventory.InventoryError as error:
                message = str(error)
                if "unknown @test declaration syntax" in message:
                    raise PolicyError("bats-inventory-declaration-invalid") from error
                if "contains no tests" in message:
                    parsed_titles = ()
                else:
                    raise PolicyError("bats-inventory-invalid") from error
            actual_titles = [
                hashlib.sha256(title.encode("utf-8")).hexdigest()
                for title in parsed_titles
            ]
            if actual_titles != titles:
                raise PolicyError("bats-inventory-title-drift")
            for title in titles:
                identifier = f"bats:{tier}:{path}:{title}"
                if identifier in references:
                    raise PolicyError("bats-inventory-invalid")
                references[identifier] = EvidenceRecord(
                    "hosted-smoke" if tier == "hosted" else "local-tcc",
                    entry["file_sha256"],
                    None,
                )
            tier_count += len(titles)
            if total + tier_count > MAX_BATS_TESTS:
                raise PolicyError("bats-catalog-too-large")
        if tier_count != tier_data["test_count"]:
            raise PolicyError("bats-inventory-counts")
        total += tier_count
    if total != raw["test_count"] or type(raw["test_count"]) is not int:
        raise PolicyError("bats-inventory-counts")
    live = raw["live"]
    if not isinstance(live, dict) or set(live) != {"files", "test_count"}:
        raise PolicyError("bats-inventory-invalid")
    live_files = live["files"]
    if (
        type(live["test_count"]) is not int
        or live["test_count"] != 0
        or not isinstance(live_files, list)
        or any(not isinstance(path, str) for path in live_files)
        or live_files != sorted(live_files)
        or len(live_files) != len(set(live_files))
    ):
        raise PolicyError("bats-inventory-invalid")
    for path in live_files:
        normalized = _repository_relative(
            path, prefix=("bats", "live"), suffix=".sh"
        )
        if normalized in seen_files:
            raise PolicyError("bats-inventory-invalid")
        if len(seen_files) >= MAX_BATS_FILES:
            raise PolicyError("bats-catalog-too-large")
        payload = _source_bytes(
            source_root,
            normalized,
            prefix=("bats", "live"),
            suffix=".sh",
        )
        seen_files.add(normalized)
        total_bytes += len(payload)
        if total_bytes > MAX_BATS_BYTES:
            raise PolicyError("bats-catalog-too-large")
    if isinstance(source_root, CommitSnapshot):
        expected = set(source_root.matching_paths("bats", ".bats"))
        expected.update(source_root.matching_paths("bats/live", ".sh"))
        if seen_files != expected:
            raise PolicyError("bats-inventory-incomplete")
    return references


def _validate_origins(source_root: Any, manifest: dict[str, Any]) -> Set[str]:
    identifiers: Set[str] = set()
    documents: Dict[str, str] = {}
    for origin in manifest["origins"]:
        if not isinstance(origin, dict) or set(origin) != {
            "anchor",
            "document",
            "id",
            "kind",
        }:
            raise PolicyError("origin-invalid")
        identifier = origin["id"]
        kind = origin["kind"]
        expected_kind = (
            "port-spec"
            if isinstance(identifier, str) and identifier.startswith("port:")
            else "cli-extra"
        )
        if (
            not isinstance(identifier, str)
            or _ORIGIN_ID.fullmatch(identifier) is None
            or kind != expected_kind
            or identifier in identifiers
        ):
            raise PolicyError("origin-invalid")
        anchor = f"<!-- capability-id: {identifier} -->"
        if origin["anchor"] != anchor:
            raise PolicyError("origin-anchor-invalid")
        prefix = ("docs", "port-specs") if kind == "port-spec" else ("docs",)
        document_path = _repository_relative(
            origin["document"], prefix=prefix, suffix=".md"
        )
        document = documents.get(document_path)
        if document is None:
            document = _source_text(
                source_root,
                document_path,
                prefix=prefix,
                suffix=".md",
            )
            documents[document_path] = document
        if document.count(anchor) != 1:
            raise PolicyError("origin-anchor-invalid")
        identifiers.add(identifier)
    if isinstance(source_root, CommitSnapshot):
        markdown_docs = source_root.matching_paths("docs", ".md")
    else:
        tracked_docs = _run_git(
            Path(source_root),
            "ls-tree",
            "-r",
            "-z",
            "--name-only",
            "HEAD",
            "--",
            "docs",
        ).split("\0")
        markdown_docs = [
            relative
            for relative in tracked_docs
            if relative and relative.endswith(".md")
        ]
    if len(markdown_docs) > MAX_ORIGIN_DOCUMENTS:
        raise PolicyError("origin-documents-too-large")
    anchor_counts: Dict[str, int] = {}
    total_bytes = 0
    for relative in markdown_docs:
        payload = _source_bytes(
            source_root,
            relative,
            prefix=("docs",),
            suffix=".md",
        )
        total_bytes += len(payload)
        if total_bytes > MAX_ORIGIN_DOCUMENT_BYTES:
            raise PolicyError("origin-documents-too-large")
        try:
            source = payload.decode("utf-8")
        except UnicodeDecodeError as error:
            raise PolicyError("text-invalid") from error
        if "<!-- capability-id:" in source:
            matched_source = _ORIGIN_ANCHOR.sub("", source)
            if "<!-- capability-id:" in matched_source:
                raise PolicyError("origin-anchor-invalid")
        for match in _ORIGIN_ANCHOR.finditer(source):
            identifier = match.group(1)
            anchor_counts[identifier] = anchor_counts.get(identifier, 0) + 1
    if set(anchor_counts) != identifiers:
        raise PolicyError("origin-anchor-orphan")
    if any(count != 1 for count in anchor_counts.values()):
        raise PolicyError("origin-anchor-invalid")
    return identifiers


def _validate_manual(source_root: Any, manifest: dict[str, Any]) -> None:
    manual_sources: Dict[str, str] = {}
    sources_by_path: Dict[str, str] = {}
    total_bytes = 0
    command_by_id = {item["id"]: item for item in manifest["commands"]}
    for command in manifest["commands"]:
        manual = command["manual"]
        if not isinstance(manual, dict) or set(manual) != {"path", "tokens"}:
            raise PolicyError("manual-invalid")
        tokens = manual["tokens"]
        if (
            not isinstance(tokens, list)
            or not tokens
            or any(not isinstance(token, str) for token in tokens)
            or len(tokens) != len(set(tokens))
            or any(
                not token
                or len(token) > 256
                or "\n" in token
                for token in tokens
            )
        ):
            raise PolicyError("manual-invalid")
        if manual["path"] != _manual_path(command["path"]):
            raise PolicyError("manual-path-invalid")
        if command["id"] not in tokens:
            raise PolicyError("manual-identity-missing")
        manual_path = _repository_relative(
            manual["path"], prefix=("docs", "manual"), suffix=".md"
        )
        source = sources_by_path.get(manual_path)
        if source is None:
            if len(sources_by_path) >= MAX_MANUAL_FILES:
                raise PolicyError("manual-sources-too-large")
            payload = _source_bytes(
                source_root,
                manual_path,
                prefix=("docs", "manual"),
                suffix=".md",
            )
            total_bytes += len(payload)
            if total_bytes > MAX_MANUAL_BYTES:
                raise PolicyError("manual-sources-too-large")
            try:
                source = payload.decode("utf-8")
            except UnicodeDecodeError as error:
                raise PolicyError("text-invalid") from error
            sources_by_path[manual_path] = source
        if any(token not in source for token in tokens):
            raise PolicyError("manual-token-missing")
        manual_sources[command["id"]] = source
    for argument in manifest["arguments"]:
        tokens = argument["manual_tokens"]
        if (
            not isinstance(tokens, list)
            or not tokens
            or any(not isinstance(token, str) for token in tokens)
            or len(tokens) != len(set(tokens))
            or any(
                not token
                or len(token) > 256
                or "\n" in token
                for token in tokens
            )
        ):
            raise PolicyError("manual-invalid")
        structure = argument["structure"]
        preferred = structure["preferred_name"]
        expected_token = (
            structure["value_name"]
            if structure["kind"] == "positional"
            else _display_name(preferred)
        )
        if expected_token not in tokens:
            raise PolicyError("manual-identity-missing")
        if argument["command_id"] not in command_by_id:
            raise PolicyError("manifest-command-reference")
        source = manual_sources[argument["command_id"]]
        if any(token not in source for token in tokens):
            raise PolicyError("manual-token-missing")


def _structural_projection(item: dict[str, Any], fields: Tuple[str, ...]) -> dict[str, Any]:
    return {field: item.get(field) for field in fields}


def _validate_runtime_bijection(manifest: dict[str, Any], dump: Any) -> None:
    runtime = snapshot_manifest(dump)
    command_fields = ("abstract", "aliases", "default_child", "id", "name", "path")
    argument_fields = (
        "command_id",
        "id",
        "position_ordinal",
        "structure",
    )
    expected_commands = {
        item["id"]: _structural_projection(item, command_fields)
        for item in runtime["commands"]
    }
    actual_commands = {
        item["id"]: _structural_projection(item, command_fields)
        for item in manifest["commands"]
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if actual_commands != expected_commands or len(actual_commands) != len(manifest["commands"]):
        raise PolicyError("runtime-command-bijection")
    expected_arguments = {
        item["id"]: _structural_projection(item, argument_fields)
        for item in runtime["arguments"]
    }
    actual_arguments = {
        item["id"]: _structural_projection(item, argument_fields)
        for item in manifest["arguments"]
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if actual_arguments != expected_arguments or len(actual_arguments) != len(
        manifest["arguments"]
    ):
        raise PolicyError("runtime-argument-bijection")


def _validate_evidence(
    manifest: dict[str, Any], catalog: Dict[str, EvidenceRecord]
) -> Dict[str, int]:
    used: Set[str] = set()
    fanout: Dict[str, int] = {}
    for surface in [*manifest["commands"], *manifest["arguments"]]:
        evidence = surface["evidence"]
        if not isinstance(evidence, dict) or set(evidence) != set(_EVIDENCE_ROLES):
            raise PolicyError("evidence-roles-invalid")
        for role in _EVIDENCE_ROLES:
            references = evidence[role]
            if (
                not isinstance(references, list)
                or not references
                or any(not isinstance(reference, str) for reference in references)
                or len(references) != len(set(references))
            ):
                raise PolicyError("evidence-role-empty")
            if references != sorted(references):
                raise PolicyError("evidence-order")
            for reference in references:
                record = catalog.get(reference)
                if record is None:
                    raise PolicyError("evidence-reference-missing")
                if role in _HOSTED_ROLES and record.tier == "local-tcc":
                    raise PolicyError("evidence-not-hosted-safe")
                used.add(reference)
                fanout[reference] = fanout.get(reference, 0) + 1
    if not set(catalog).issubset(used):
        raise PolicyError("test-catalog-orphan")
    return fanout


class RuntimeEvidence(NamedTuple):
    dump: Any
    passed_swift_runtime_ids: FrozenSet[str]
    binary_sha256: str


def _valid_runtime_id(value: Any) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= 512
        and all(ord(character) >= 32 and ord(character) != 127 for character in value)
    )


def _runtime_id_matches_symbol(runtime_id: str, symbol: str) -> bool:
    suite, separator, test_name = runtime_id.rpartition("::")
    if not separator or not suite:
        return False
    return re.fullmatch(re.escape(symbol) + r"(?:\([^\r\n]*\))?", test_name) is not None


def _passed_xunit_ids(payload: bytes) -> FrozenSet[str]:
    # Swift emits UTF-8 xUnit. Decode before checking declarations so XML's own
    # encoding detection cannot turn interleaved UTF-16/32 bytes into a hidden DTD.
    try:
        source = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PolicyError("runtime-xunit-invalid") from error
    lowered = source.lower()
    if "\x00" in source or "<!doctype" in lowered or "<!entity" in lowered:
        raise PolicyError("runtime-xunit-invalid")
    try:
        root = ElementTree.fromstring(source)
    except ElementTree.ParseError as error:
        raise PolicyError("runtime-xunit-invalid") from error
    passed: Set[str] = set()
    seen: Set[str] = set()
    testcase_count = 0
    node_count = 0
    for element in root.iter():
        node_count += 1
        if node_count > schema.MAX_JSON_NODES:
            raise PolicyError("runtime-xunit-too-large")
        if element.tag.split("}", 1)[-1] != "testcase":
            continue
        testcase_count += 1
        if testcase_count > MAX_SWIFT_TESTS:
            raise PolicyError("runtime-xunit-too-large")
        class_name = element.attrib.get("classname")
        name = element.attrib.get("name")
        runtime_id = f"{class_name}::{name}"
        if not _valid_runtime_id(class_name) or not _valid_runtime_id(name):
            raise PolicyError("runtime-xunit-invalid")
        if runtime_id in seen:
            raise PolicyError("runtime-xunit-invalid")
        seen.add(runtime_id)
        outcomes = {
            child.tag.split("}", 1)[-1]
            for child in element
            if child.tag.split("}", 1)[-1] in {"error", "failure", "skipped"}
        }
        if not outcomes:
            passed.add(runtime_id)
    if testcase_count == 0 or not passed:
        raise PolicyError("runtime-xunit-invalid")
    return frozenset(passed)


def _runner_environment(temporary_root: Path) -> dict[str, str]:
    home = temporary_root / "home"
    temporary = temporary_root / "tmp"
    home.mkdir()
    temporary.mkdir()
    environment = {
        "HOME": str(home),
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": str(temporary),
    }
    for key in ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"):
        value = os.environ.get(key)
        if value:
            environment[key] = value
    return environment


def _default_runtime_runner(root: Path, sha: str, tree_oid: str) -> bytes:
    """Build, execute the full Swift suite, and dump the freshly built CLI."""
    swift = shutil.which("swift", path=os.environ.get("PATH", "/usr/bin:/bin"))
    if swift is None or not Path(swift).is_absolute():
        raise PolicyError("runtime-runner-unavailable")
    with tempfile.TemporaryDirectory(prefix="apple-cli-capability-") as directory:
        temporary_root = Path(directory).resolve()
        scratch = temporary_root / "build"
        xunit = temporary_root / "swift-tests.xml"
        environment = _runner_environment(temporary_root)
        common = [
            "--package-path",
            str(root),
            "--scratch-path",
            str(scratch),
            "--disable-automatic-resolution",
        ]
        _run_bounded_command(
            [swift, "test", *common, "--xunit-output", str(xunit)],
            cwd=root,
            environment=environment,
            timeout=MAX_RUNTIME_SECONDS,
            maximum=MAX_RUNNER_OUTPUT_BYTES,
            failure="runtime-tests-failed",
            output_failure="runtime-output-too-large",
        )
        xunit_payload = _read_regular_bytes(xunit, MAX_XUNIT_BYTES)
        passed = _passed_xunit_ids(xunit_payload)
        _run_bounded_command(
            [swift, "build", *common, "--product", "apple"],
            cwd=root,
            environment=environment,
            timeout=MAX_RUNTIME_SECONDS,
            maximum=MAX_RUNNER_OUTPUT_BYTES,
            failure="runtime-build-failed",
            output_failure="runtime-output-too-large",
        )
        bin_path_output = _run_bounded_command(
            [swift, "build", *common, "--show-bin-path"],
            cwd=root,
            environment=environment,
            timeout=MAX_RUNTIME_SECONDS,
            maximum=4096,
            failure="runtime-build-failed",
            output_failure="runtime-output-too-large",
        )
        try:
            bin_directory = Path(bin_path_output.decode("utf-8").strip()).resolve(
                strict=True
            )
            bin_directory.relative_to(scratch.resolve(strict=True))
        except (UnicodeDecodeError, OSError, ValueError) as error:
            raise PolicyError("runtime-binary-invalid") from error
        binary = bin_directory / "apple"
        binary_payload = _read_regular_bytes(binary, MAX_BINARY_BYTES)
        dump_payload = _run_bounded_command(
            [str(binary), "--experimental-dump-help"],
            cwd=root,
            environment=environment,
            timeout=60,
            maximum=MAX_RUNTIME_DUMP_BYTES,
            failure="runtime-dump-failed",
            output_failure="runtime-output-too-large",
        )
        attestation = {
            "binary_sha256": hashlib.sha256(binary_payload).hexdigest(),
            "contract": RUNTIME_CONTRACT,
            "dump_base64": base64.b64encode(dump_payload).decode("ascii"),
            "dump_sha256": hashlib.sha256(dump_payload).hexdigest(),
            "passed_swift_runtime_ids": sorted(passed),
            "schema_version": 1,
            "sha": sha,
            "tree_oid": tree_oid,
        }
        return canonical_json(attestation).encode("utf-8")


def _parse_runtime_attestation(
    payload: Any,
    *,
    sha: str,
    tree_oid: str,
) -> RuntimeEvidence:
    if not isinstance(payload, bytes) or len(payload) > MAX_RUNTIME_ATTESTATION_BYTES:
        raise PolicyError("runtime-attestation-invalid")
    try:
        value = schema.parse_json_bytes(payload)
    except schema.SchemaError as error:
        raise PolicyError("runtime-attestation-invalid") from error
    if payload != canonical_json(value).encode("utf-8"):
        raise PolicyError("runtime-attestation-invalid")
    if not isinstance(value, dict) or set(value) != {
        "binary_sha256",
        "contract",
        "dump_base64",
        "dump_sha256",
        "passed_swift_runtime_ids",
        "schema_version",
        "sha",
        "tree_oid",
    }:
        raise PolicyError("runtime-attestation-invalid")
    if value["sha"] != sha or value["tree_oid"] != tree_oid:
        raise PolicyError("runtime-sha-mismatch")
    passed = value["passed_swift_runtime_ids"]
    if (
        value["schema_version"] != 1
        or type(value["schema_version"]) is not int
        or value["contract"] != RUNTIME_CONTRACT
        or not isinstance(value["binary_sha256"], str)
        or _SHA256.fullmatch(value["binary_sha256"]) is None
        or not isinstance(value["dump_sha256"], str)
        or _SHA256.fullmatch(value["dump_sha256"]) is None
        or not isinstance(value["dump_base64"], str)
        or not isinstance(passed, list)
        or not passed
        or passed != sorted(passed)
        or len(passed) != len(set(passed))
        or len(passed) > MAX_SWIFT_TESTS
        or any(not _valid_runtime_id(identifier) for identifier in passed)
    ):
        raise PolicyError("runtime-attestation-invalid")
    try:
        dump_payload = base64.b64decode(value["dump_base64"], validate=True)
    except (ValueError, TypeError) as error:
        raise PolicyError("runtime-attestation-invalid") from error
    if (
        len(dump_payload) > MAX_RUNTIME_DUMP_BYTES
        or hashlib.sha256(dump_payload).hexdigest() != value["dump_sha256"]
    ):
        raise PolicyError("runtime-attestation-invalid")
    try:
        dump = schema.parse_json_bytes(dump_payload)
    except schema.SchemaError as error:
        raise PolicyError("runtime-dump-invalid") from error
    return RuntimeEvidence(
        dump,
        frozenset(passed),
        value["binary_sha256"],
    )


def _capture_candidate(
    repository_root: Path,
    sha: str,
) -> CandidateDetails:
    """Capture and validate one immutable exact-commit candidate."""
    root = _validate_checkout(Path(repository_root), sha)
    snapshot = CommitSnapshot.capture(root, sha)
    try:
        manifest_data = _blob_json(snapshot, MANIFEST_PATH, canonical=True)
        catalog_data = _blob_json(snapshot, SWIFT_CATALOG_PATH, canonical=True)
        bats_data = _blob_json(snapshot, BATS_INVENTORY_PATH, canonical=False)
        try:
            schema.validate_manifest(manifest_data)
        except schema.SchemaError as error:
            raise PolicyError(str(error)) from error
        if manifest_data["status"] != "curated":
            raise PolicyError("manifest-not-curated")

        origin_ids = _validate_origins(snapshot, manifest_data)
        used_origin_ids = {
            surface.get("origin_id")
            for surface in [*manifest_data["commands"], *manifest_data["arguments"]]
        }
        if used_origin_ids != origin_ids:
            raise PolicyError("origin-orphan-or-missing")
        _validate_manual(snapshot, manifest_data)
        bats_catalog = _bats_catalog(snapshot, bats_data)

        try:
            with _materialized_snapshot(snapshot) as source_root:
                attestation_payload = _default_runtime_runner(
                    source_root,
                    sha,
                    snapshot.tree_oid,
                )
        except PolicyError:
            raise
        except Exception as error:
            raise PolicyError("runtime-runner-failed") from error
        runtime = _parse_runtime_attestation(
            attestation_payload,
            sha=sha,
            tree_oid=snapshot.tree_oid,
        )
        _validate_runtime_bijection(manifest_data, runtime.dump)
        evidence_catalog = _swift_catalog(
            snapshot,
            catalog_data,
            runtime.passed_swift_runtime_ids,
        )
        for identifier, record in bats_catalog.items():
            if identifier in evidence_catalog:
                raise PolicyError("evidence-catalog-duplicate")
            evidence_catalog[identifier] = record
        fanout = _validate_evidence(manifest_data, evidence_catalog)
        report = {
            "binary_sha256": runtime.binary_sha256,
            "contract_stage": schema.CONTRACT_STAGE,
            "counts": manifest_data["counts"],
            "max_evidence_fanout": max(fanout.values()) if fanout else 0,
            "ok": True,
            "sha": sha,
            "tree_oid": snapshot.tree_oid,
        }
        return CandidateDetails(root, sha, manifest_data, evidence_catalog, report)
    finally:
        _validate_checkout(root, sha)


def check_candidate(
    *,
    repository_root: Path,
    sha: str,
    **candidate_artifacts: Any,
) -> dict[str, Any]:
    """Check fixed policy blobs and executed runtime evidence for one exact SHA."""
    if candidate_artifacts:
        raise PolicyError("artifact-path-invalid")
    return _capture_candidate(repository_root, sha).report


def _checked_candidate_details(candidate: dict[str, Any]) -> CandidateDetails:
    if not isinstance(candidate, dict) or set(candidate) != {
        "repository_root",
        "sha",
    }:
        raise PolicyError("compare-input-invalid")
    return _capture_candidate(
        Path(candidate["repository_root"]),
        candidate["sha"],
    )


def _command_compare_structure(command: dict[str, Any]) -> dict[str, Any]:
    return {
        "default_child": command["default_child"],
        "name": command["name"],
        "path": command["path"],
    }


def _argument_compare_structure(argument: dict[str, Any]) -> dict[str, Any]:
    structure = argument["structure"]
    return {
        "command_id": argument["command_id"],
        "position_ordinal": argument["position_ordinal"],
        **{
            key: value
            for key, value in structure.items()
            if key not in {"abstract", "names"}
        },
    }


def _argument_names(argument: dict[str, Any]) -> Set[Tuple[str, str]]:
    return {
        (name["kind"], name["name"])
        for name in argument["structure"]["names"]
    }


def compare_candidates(
    *, base: dict[str, Any], head: dict[str, Any]
) -> dict[str, Any]:
    """Reject command/argument capability-policy regressions between exact checkouts."""
    base_details = _checked_candidate_details(base)
    head_details = _checked_candidate_details(head)
    base_manifest = base_details.manifest
    head_manifest = head_details.manifest
    base_commands = {item["id"]: item for item in base_manifest["commands"]}
    head_commands = {item["id"]: item for item in head_manifest["commands"]}
    base_arguments = {item["id"]: item for item in base_manifest["arguments"]}
    head_arguments = {item["id"]: item for item in head_manifest["arguments"]}
    try:
        if base_manifest["supersedes"] != head_manifest["supersedes"]:
            raise PolicyError("compare-supersedes-frozen")
        if not set(base_commands).issubset(head_commands) or not set(
            base_arguments
        ).issubset(head_arguments):
            raise PolicyError("compare-surface-removal")

        for identifier, base_command in base_commands.items():
            head_command = head_commands[identifier]
            if _command_compare_structure(base_command) != _command_compare_structure(
                head_command
            ) or not set(base_command["aliases"]).issubset(head_command["aliases"]):
                raise PolicyError("compare-command-structure-change")

        for identifier, base_argument in base_arguments.items():
            head_argument = head_arguments[identifier]
            if _argument_compare_structure(
                base_argument
            ) != _argument_compare_structure(head_argument) or not _argument_names(
                base_argument
            ).issubset(
                _argument_names(head_argument)
            ):
                raise PolicyError("compare-argument-structure-change")

        for identifier, base_surface in [
            *base_commands.items(),
            *base_arguments.items(),
        ]:
            head_surface = (
                head_commands[identifier]
                if identifier in base_commands
                else head_arguments[identifier]
            )
            if head_surface["origin_id"] != base_surface["origin_id"]:
                raise PolicyError("compare-origin-change")
            for role in _EVIDENCE_ROLES:
                base_references = set(base_surface["evidence"][role])
                head_references = set(head_surface["evidence"][role])
                if not base_references.issubset(head_references):
                    raise PolicyError("compare-evidence-removal")

        base_used = {
            reference
            for surface in [*base_manifest["commands"], *base_manifest["arguments"]]
            for role in _EVIDENCE_ROLES
            for reference in surface["evidence"][role]
        }
        for reference in base_used:
            if base_details.catalog.get(reference) != head_details.catalog.get(reference):
                raise PolicyError("compare-test-content-change")
        return {
            "contract_stage": schema.CONTRACT_STAGE,
            "new_arguments": len(set(head_arguments) - set(base_arguments)),
            "new_commands": len(set(head_commands) - set(base_commands)),
            "ok": True,
        }
    finally:
        _validate_checkout(base_details.root, base_details.sha)
        _validate_checkout(head_details.root, head_details.sha)


def _add_candidate_arguments(parser: argparse.ArgumentParser, prefix: str = "") -> None:
    option_prefix = f"{prefix}-" if prefix else ""
    destination_prefix = f"{prefix}_" if prefix else ""
    parser.add_argument(
        f"--{option_prefix}repository-root",
        dest=f"{destination_prefix}repository_root",
        required=True,
    )
    sha_option = f"--expected-{prefix}-sha" if prefix else "--expected-sha"
    parser.add_argument(sha_option, dest=f"{destination_prefix}sha", required=True)


def _candidate_from_namespace(
    namespace: argparse.Namespace, prefix: str = ""
) -> dict[str, Any]:
    attribute_prefix = f"{prefix}_" if prefix else ""
    return {
        "repository_root": Path(getattr(namespace, f"{attribute_prefix}repository_root")),
        "sha": getattr(namespace, f"{attribute_prefix}sha"),
    }


def main(argv: Optional[list[str]] = None) -> int:
    try:
        parser = _ValueFreeArgumentParser(description=__doc__, allow_abbrev=False)
        subparsers = parser.add_subparsers(dest="operation", required=True)
        snapshot_parser = subparsers.add_parser("snapshot", allow_abbrev=False)
        snapshot_parser.add_argument("--dump", required=True)
        check_parser = subparsers.add_parser("check", allow_abbrev=False)
        _add_candidate_arguments(check_parser)
        compare_parser = subparsers.add_parser("compare", allow_abbrev=False)
        _add_candidate_arguments(compare_parser, "base")
        _add_candidate_arguments(compare_parser, "head")
        namespace = parser.parse_args(argv)
        if namespace.operation == "snapshot":
            result = snapshot_manifest(_load_json(Path(namespace.dump)))
        elif namespace.operation == "check":
            candidate = _candidate_from_namespace(namespace)
            result = check_candidate(**candidate)
        else:
            base = _candidate_from_namespace(namespace, "base")
            head = _candidate_from_namespace(namespace, "head")
            result = compare_candidates(
                base=base,
                head=head,
            )
    except (PolicyError, schema.SchemaError) as error:
        sys.stderr.write(f"capability-policy: {error}\n")
        return 2
    sys.stdout.write(canonical_json(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
