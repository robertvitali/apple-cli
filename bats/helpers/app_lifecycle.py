#!/usr/bin/env python3
"""Validate and plan local-Bats Apple app lifecycle state."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any, Iterable, Mapping


APPLICATION_KEYS = ("mail", "notes", "messages", "contacts", "calendar", "reminders")
APPLICATION_IDENTITIES = {
    "mail": ("Mail", "com.apple.mail"),
    "notes": ("Notes", "com.apple.Notes"),
    "messages": ("Messages", "com.apple.MobileSMS"),
    "contacts": ("Contacts", "com.apple.AddressBook"),
    "calendar": ("Calendar", "com.apple.iCal"),
    "reminders": ("Reminders", "com.apple.reminders"),
}
SCHEMA_VERSION = 1
MAX_STATE_BYTES = 4096
MAX_FIND_BYTES = 4096
MAX_INFO_BYTES = 8192
MAX_CHECKIN_BYTES = 1024
PRESERVE_ENV = "APPLE_CLI_BATS_PRESERVE_APPS"
GENERIC_ERROR = "app lifecycle operation failed"


class LifecycleError(RuntimeError):
    """Lifecycle state could not be processed safely.

    `code` is a fixed, value-free reason token (never any byte of the input) so a failing run
    can say WHICH check refused without echoing process names, timestamps, or file contents.
    """

    def __init__(self, message: str = GENERIC_ERROR, code: str = "") -> None:
        super().__init__(message)
        self.code = code


class LifecycleArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise LifecycleError(GENERIC_ERROR)


def _strict_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise LifecycleError(GENERIC_ERROR)
        result[key] = value
    return result


def _validate_token(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) != len(APPLICATION_KEYS)
        or not value.isascii()
        or any(character not in "01" for character in value)
    ):
        raise LifecycleError(GENERIC_ERROR)
    return value


def _read_private_bytes(path: Path, maximum: int) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = None
    try:
        descriptor = os.open(str(path), flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise LifecycleError(GENERIC_ERROR)
        if metadata.st_size > maximum:
            raise LifecycleError(GENERIC_ERROR)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > maximum or len(payload) != metadata.st_size:
            raise LifecycleError(GENERIC_ERROR)
    except LifecycleError:
        raise
    except OSError as error:
        raise LifecycleError(GENERIC_ERROR) from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as error:
                raise LifecycleError(GENERIC_ERROR) from error
    return payload


def _read_state(path: Path) -> dict[str, Any]:
    payload = _read_private_bytes(path, MAX_STATE_BYTES)
    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_strict_object)
    except LifecycleError:
        raise
    except (json.JSONDecodeError, UnicodeError, RecursionError) as error:
        raise LifecycleError(GENERIC_ERROR) from error
    if not isinstance(value, dict) or set(value) != {"schema_version", "disabled", "running"}:
        raise LifecycleError(GENERIC_ERROR)
    if type(value["schema_version"]) is not int or value["schema_version"] != SCHEMA_VERSION:
        raise LifecycleError(GENERIC_ERROR)
    if not isinstance(value["disabled"], bool):
        raise LifecycleError(GENERIC_ERROR)
    running = _validate_token(value["running"])
    if value["disabled"] and running != "000000":
        raise LifecycleError(GENERIC_ERROR)
    return value


ASN_PATTERN = re.compile(r"ASN:0x[0-9A-Fa-f]+-0x[0-9A-Fa-f]+")
CHECKIN_TIMESTAMP_PATTERN = (
    r"[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
)
CHECKIN_DISPLAY_PATTERN = re.compile(
    rf'^(?:"(?:[0-9]+ seconds? ago, )?({CHECKIN_TIMESTAMP_PATTERN})"|'
    rf'(?:[0-9]+ seconds? ago, )?({CHECKIN_TIMESTAMP_PATTERN}))$'
)


def _application_identity(key: str) -> tuple[str, str]:
    try:
        return APPLICATION_IDENTITIES[key]
    except KeyError as error:
        raise LifecycleError(GENERIC_ERROR) from error


def _parse_find_file(path: Path, expected_name: str) -> str | None:
    try:
        payload = _read_private_bytes(path, MAX_FIND_BYTES).decode("ascii")
    except UnicodeError as error:
        raise LifecycleError(GENERIC_ERROR) from error
    if payload in {"", "\n"}:
        return None
    lines = payload.splitlines()
    if len(lines) != 1 or not lines[0]:
        raise LifecycleError(GENERIC_ERROR, "find-multiple")
    line = lines[0]
    match = ASN_PATTERN.fullmatch(line[:-1]) if line.endswith(":") else None
    if match is not None:
        return match.group(0)
    suffix = f'-"{expected_name}":'
    if not line.endswith(suffix):
        raise LifecycleError(GENERIC_ERROR, "find-name")
    base = line[: -len(suffix)]
    if ASN_PATTERN.fullmatch(base) is None:
        raise LifecycleError(GENERIC_ERROR, "find-asn")
    return base


def parse_find_outputs(key: str, bundle_path: Path, exact_path: Path) -> str:
    expected_name, _ = _application_identity(key)
    values = tuple(
        _parse_find_file(path, expected_name)
        for path in (bundle_path, exact_path)
    )
    if values == (None, None):
        return "NONE"
    if values[0] is not None and values[0] == values[1]:
        return values[0]
    raise LifecycleError(GENERIC_ERROR, "find-bundle-exact-disagree")


def _parse_info_fields(path: Path) -> dict[str, str]:
    try:
        payload = _read_private_bytes(path, MAX_INFO_BYTES).decode("ascii")
    except UnicodeError as error:
        raise LifecycleError(GENERIC_ERROR) from error
    fields: dict[str, str] = {}
    allowed = {"LSDisplayName", "pid", "CFBundleIdentifier", "LSCheckInTime*"}
    for line in payload.splitlines():
        if "=" not in line:
            raise LifecycleError(GENERIC_ERROR, "info-line-shape")
        raw_key, value = line.split("=", 1)
        value = value.strip(" \t")
        key = raw_key[1:-1] if len(raw_key) >= 2 and raw_key[0] == raw_key[-1] == '"' else raw_key
        if key not in allowed or key in fields or value == "":
            raise LifecycleError(GENERIC_ERROR, "info-field")
        fields[key] = value
    if set(fields) != allowed:
        raise LifecycleError(GENERIC_ERROR, "info-fields-missing")
    return fields


def _strict_pid(value: str) -> str:
    """Reject anything but a plain positive 32-bit pid rendering."""
    if (
        not value.isascii()
        or not value.isdecimal()
        or len(value) > 10
        or int(value) <= 1
        or int(value) > 2147483647
    ):
        raise LifecycleError(GENERIC_ERROR, "info-pid")
    return value


def parse_info_output(key: str, asn: str, output_path: Path) -> str:
    expected_name, expected_bundle = _application_identity(key)
    if ASN_PATTERN.fullmatch(asn) is None:
        raise LifecycleError(GENERIC_ERROR)
    fields = _parse_info_fields(output_path)
    values = tuple(fields[name] for name in ("LSDisplayName", "pid", "CFBundleIdentifier", "LSCheckInTime*"))
    stopped_value = "[ NULL ]"
    if values == (stopped_value, stopped_value, stopped_value, stopped_value):
        return "STOPPED"
    if stopped_value in values:
        raise LifecycleError(GENERIC_ERROR, "info-partial-null")
    if fields["LSDisplayName"] != f'"{expected_name}"':
        raise LifecycleError(GENERIC_ERROR, "info-name-mismatch")
    if fields["CFBundleIdentifier"] != f'"{expected_bundle}"':
        raise LifecycleError(GENERIC_ERROR, "info-bundle-mismatch")
    pid = _strict_pid(fields["pid"])
    checkin = fields["LSCheckInTime*"]
    if (
        checkin == '""'
        or not checkin.isascii()
        or not all(0x20 <= ord(character) <= 0x7E for character in checkin)
        or len(checkin.encode("ascii")) > MAX_CHECKIN_BYTES
    ):
        raise LifecycleError(GENERIC_ERROR, "info-checkin")
    match = CHECKIN_DISPLAY_PATTERN.fullmatch(checkin)
    stable_checkin = (
        next(value for value in match.groups() if value)
        if match is not None
        else checkin
    )
    digest = hashlib.sha256(stable_checkin.encode("ascii")).hexdigest()
    return f"{asn}\t{pid}\t{digest}"


def _write_state(path: Path, payload: dict[str, Any]) -> None:
    encoded = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = None
    try:
        descriptor = os.open(str(path), flags, 0o600)
        os.fchmod(descriptor, 0o600)
        written = 0
        while written < len(encoded):
            count = os.write(descriptor, encoded[written:])
            if count <= 0:
                raise LifecycleError(GENERIC_ERROR)
            written += count
    except LifecycleError:
        raise
    except OSError as error:
        raise LifecycleError(GENERIC_ERROR) from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as error:
                raise LifecycleError(GENERIC_ERROR) from error


def preserve_requested(environment: Mapping[str, str]) -> bool:
    value = environment.get(PRESERVE_ENV)
    if value is None:
        return False
    if value in {"1", "true", "yes"}:
        return True
    raise LifecycleError(GENERIC_ERROR)


def write_snapshot(path: Path, *, disabled: bool, running: str) -> None:
    running = _validate_token(running)
    if disabled and running != "000000":
        raise LifecycleError(GENERIC_ERROR)
    _write_state(
        path,
        {"schema_version": SCHEMA_VERSION, "disabled": disabled, "running": running},
    )


def restore_plan(path: Path, current: str) -> tuple[str, ...]:
    current = _validate_token(current)
    state = _read_state(path)
    if state["disabled"]:
        return ()
    return tuple(
        key
        for index, key in enumerate(APPLICATION_KEYS)
        if state["running"][index] == "0" and current[index] == "1"
    )


def finish_restore(path: Path) -> None:
    _read_state(path)
    try:
        path.unlink()
    except OSError as error:
        raise LifecycleError(GENERIC_ERROR) from error


def _parser() -> argparse.ArgumentParser:
    parser = LifecycleArgumentParser(description=__doc__, add_help=False)
    commands = parser.add_subparsers(dest="operation", required=True)
    snapshot = commands.add_parser("write-snapshot")
    snapshot.add_argument("--state", required=True, type=Path)
    snapshot.add_argument("--running", required=True)
    snapshot.add_argument("--disabled", action="store_true")
    plan = commands.add_parser("restore-plan")
    plan.add_argument("--state", required=True, type=Path)
    plan.add_argument("--current", required=True)
    finish = commands.add_parser("finish-restore")
    finish.add_argument("--state", required=True, type=Path)
    parse_find = commands.add_parser("parse-find")
    parse_find.add_argument("--app", required=True, choices=APPLICATION_KEYS)
    parse_find.add_argument("--bundle-output", required=True, type=Path)
    parse_find.add_argument("--exact-output", required=True, type=Path)
    parse_info = commands.add_parser("parse-info")
    parse_info.add_argument("--app", required=True, choices=APPLICATION_KEYS)
    parse_info.add_argument("--asn", required=True)
    parse_info.add_argument("--output", required=True, type=Path)
    return parser


def run(argv: list[str]) -> int:
    try:
        arguments = _parser().parse_args(argv)
        if arguments.operation == "write-snapshot":
            write_snapshot(
                arguments.state,
                disabled=arguments.disabled,
                running=arguments.running,
            )
        elif arguments.operation == "restore-plan":
            for key in restore_plan(arguments.state, arguments.current):
                print(key)
        elif arguments.operation == "finish-restore":
            finish_restore(arguments.state)
        elif arguments.operation == "parse-find":
            print(parse_find_outputs(
                arguments.app,
                arguments.bundle_output,
                arguments.exact_output,
            ))
        else:
            print(parse_info_output(arguments.app, arguments.asn, arguments.output))
    except KeyboardInterrupt:
        print("app lifecycle interrupted", file=sys.stderr)
        return 130
    except LifecycleError as error:
        # The code is a fixed token from this file, never derived from the input.
        print(f"{GENERIC_ERROR}: {error.code}" if error.code else GENERIC_ERROR, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
