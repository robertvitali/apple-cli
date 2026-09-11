"""Pure process records and bounded canonical frames; no ownership authority.

Callers supply original requests and correlation data. Nothing in this module
qualifies a runtime, opens a path, reads a clock or launches a process.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import re
from typing import Optional, Tuple


MAX_REQUEST_BYTES = 64 * 1024
MAX_RECEIPT_BYTES = 4096
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_ARGV = 256
MAX_ENVIRONMENT = 128
MAX_ARGUMENT_BYTES = 4096
MAX_ENVIRONMENT_VALUE_BYTES = 8192
MAX_PATH_BYTES = 4096
MAX_COMMAND_ID = 2**53 - 1
MAX_JSON_DEPTH = 8
MAX_JSON_ITEMS = 4096
BOOTSTRAP_OUTPUT_BYTES = 1024 * 1024
ROLE_SECONDS = {"git": 10.0, "swift-test": 1800.0, "swift-build": 1800.0,
                "swift-bin-path": 1800.0, "help-dump": 60.0}
FAILURE_REASONS = frozenset(("command-failed", "output-limit", "deadline", "cancelled",
    "process-unavailable", "ownership-lost", "protocol-invalid", "identity-drift", "cleanup-failed"))
CLEANUP_DISPOSITIONS = frozenset(("not-needed", "complete", "failed", "authority-lost"))
SESSION_DISPOSITIONS = frozenset(("ready", "poisoned", "closed"))
OUTCOMES = frozenset(("success", "command-failed", "output-limit", "deadline", "launch-failed", "read-failed"))
_GIT_ENV = (("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_NO_REPLACE_OBJECTS", "1"), ("GIT_OPTIONAL_LOCKS", "0"),
            ("LC_ALL", "C"), ("PATH", "/usr/bin:/bin"))
_BOOT_ENV = (("LC_ALL", "C"), ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"))
_BUILD_KEYS = frozenset(("HOME", "TMPDIR", "LC_ALL", "PATH", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"))
_BUILD_REQUIRED = frozenset(("HOME", "TMPDIR", "LC_ALL", "PATH"))
_FILE_FIELDS = frozenset(("path", "sha256", "device", "inode", "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"))
_SDK_FIELDS = frozenset(("path", "manifest_sha256", "device", "inode", "mode", "uid", "gid"))
_CONTEXT_FIELDS = frozenset(("version", "role", "session_id", "command_id", "trusted_closure_sha256", "profile_id"))
_OPERATION_FIELDS = _CONTEXT_FIELDS | frozenset(("native_artifact_sha256", "executable", "argv", "cwd", "environment", "deadline", "maximum_output_bytes"))
_BOOTSTRAP_FIELDS = _CONTEXT_FIELDS | frozenset(("compiler", "source", "sdk", "cwd", "environment", "deadline", "maximum_output_bytes"))
_RECEIPT_FIELDS = frozenset(("outcome", "command_status", "stdout_bytes", "stderr_bytes", "stdout_sha256", "stderr_sha256"))


def _status(value: object) -> bool:
    return type(value) is int and -31 <= value <= 255


class ProcessFailure(Exception):
    """Closed public reason and typed dispositions, without raw diagnostic data."""
    def __init__(self, reason: str, *, command_status: Optional[int] = None,
                 cleanup_disposition: str = "not-needed", session_disposition: str = "poisoned"):
        if not (type(reason) is str and reason in FAILURE_REASONS
                and (command_status is None or _status(command_status))
                and type(cleanup_disposition) is str and cleanup_disposition in CLEANUP_DISPOSITIONS
                and type(session_disposition) is str and session_disposition in SESSION_DISPOSITIONS):
            raise ProcessFailure("protocol-invalid")
        super().__init__(reason)
        self.reason = reason
        self.command_status = command_status
        self.cleanup_disposition = cleanup_disposition
        self.session_disposition = session_disposition


def _need(condition: bool) -> None:
    if not condition:
        raise ProcessFailure("protocol-invalid")


def _integer(value: object, maximum: int, minimum: int = 0) -> None:
    _need(type(value) is int and minimum <= value <= maximum)


def _text(value: object, maximum: int, *, nonempty: bool = False) -> None:
    _need(type(value) is str and len(value) <= maximum and "\x00" not in value)
    _need(not nonempty or bool(value))
    try:
        _need(len(value.encode("utf-8", errors="strict")) <= maximum)
    except UnicodeError:
        raise ProcessFailure("protocol-invalid") from None


def _path(value: object) -> None:
    _text(value, MAX_PATH_BYTES, nonempty=True)
    _need(value.startswith("/") and (value == "/" or all(
        part not in ("", ".", "..") for part in value[1:].split("/"))))


def _sha(value: object) -> None:
    _need(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None)


def _time(value: object) -> None:
    _need(type(value) is float and math.isfinite(value) and value >= 0.0)


def _deadline(deadline: float, now: float, role: str) -> None:
    _time(now)
    _time(deadline)
    allowance = 58.0 if role == "compiler-bootstrap" else ROLE_SECONDS[role]
    _need(now < deadline and deadline - now <= allowance)


@dataclass(frozen=True)
class ExecutableIdentity:
    path: str
    sha256: str
    device: int
    inode: int
    size: int
    mode: int
    uid: int
    gid: int
    mtime_ns: int
    ctime_ns: int

    def __post_init__(self):
        _file_identity(self)


def _file_identity(value: ExecutableIdentity, *, executable: bool = False) -> None:
    _need(type(value) is ExecutableIdentity)
    _path(value.path)
    _sha(value.sha256)
    for name in ("device", "inode", "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"):
        _integer(getattr(value, name), 2**64 - 1)
    _need(value.mode & 0o170000 == 0o100000)
    if executable:
        _need(bool(value.mode & 0o111))


@dataclass(frozen=True)
class SDKIdentity:
    path: str
    manifest_sha256: str
    device: int
    inode: int
    mode: int
    uid: int
    gid: int

    def __post_init__(self):
        _sdk_identity(self)


def _sdk_identity(value: SDKIdentity) -> None:
    _need(type(value) is SDKIdentity)
    _path(value.path)
    _sha(value.manifest_sha256)
    for name in ("device", "inode", "mode", "uid", "gid"):
        _integer(getattr(value, name), 2**64 - 1)
    _need(value.mode & 0o170000 == 0o040000)


@dataclass(frozen=True)
class ProtocolContext:
    """Correlation data only, deliberately separate from TrustedEntryContext."""
    session_id: str
    command_id: int
    trusted_closure_sha256: str
    profile_id: str
    native_artifact_sha256: Optional[str]

    def __post_init__(self):
        _context_shape(self)


def _context_shape(value: ProtocolContext) -> None:
    _need(type(value) is ProtocolContext)
    _need(type(value.session_id) is str and re.fullmatch(r"[0-9a-f]{32}", value.session_id) is not None)
    _integer(value.command_id, MAX_COMMAND_ID, 1)
    _sha(value.trusted_closure_sha256)
    _need(type(value.profile_id) is str and re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", value.profile_id) is not None)
    if value.native_artifact_sha256 is not None:
        _sha(value.native_artifact_sha256)


def _context(value: ProtocolContext, *, bootstrap: bool) -> None:
    _context_shape(value)
    _need((value.native_artifact_sha256 is None) == bootstrap)


def _bounded_environment(value: object) -> None:
    _need(type(value) is tuple and len(value) <= MAX_ENVIRONMENT)
    previous = None
    for pair in value:
        _need(type(pair) is tuple and len(pair) == 2)
        key, entry = pair
        _text(key, 128, nonempty=True)
        _need(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is not None)
        _text(entry, MAX_ENVIRONMENT_VALUE_BYTES)
        _need(previous is None or previous < key)
        previous = key


def _environment(value: object, role: str) -> None:
    _bounded_environment(value)
    if role == "git":
        _need(value == _GIT_ENV)
    elif role == "compiler-bootstrap":
        _need(value == _BOOT_ENV)
    else:
        keys = frozenset(key for key, _ in value)
        _need(_BUILD_REQUIRED <= keys <= _BUILD_KEYS)
        entries = dict(value)
        _need(entries["LC_ALL"] == "C")
        _path(entries["HOME"])
        _path(entries["TMPDIR"])
        _need(bool(entries["PATH"]))


@dataclass(frozen=True, init=False)
class CommandRequest:
    role: str
    executable: ExecutableIdentity
    argv: Tuple[str, ...]
    cwd: Path
    environment: Tuple[Tuple[str, str], ...]
    deadline: float
    maximum_output_bytes: int

    # Explicit keyword-only construction works on the supported CPython 3.9.
    def __init__(self, *, role: str, executable: ExecutableIdentity, argv: Tuple[str, ...],
                 cwd: Path, environment: Tuple[Tuple[str, str], ...], deadline: float,
                 maximum_output_bytes: int):
        for name, value in (("role", role), ("executable", executable), ("argv", argv),
                            ("cwd", cwd), ("environment", environment), ("deadline", deadline),
                            ("maximum_output_bytes", maximum_output_bytes)):
            object.__setattr__(self, name, value)
        _command(self)


def _command(value: CommandRequest) -> None:
    _need(type(value) is CommandRequest and type(value.role) is str and value.role in ROLE_SECONDS)
    _file_identity(value.executable, executable=True)
    _need(type(value.argv) is tuple and 0 < len(value.argv) <= MAX_ARGV)
    for argument in value.argv:
        _text(argument, MAX_ARGUMENT_BYTES)
    _need(value.argv[0] == value.executable.path)
    _need(type(value.cwd) is type(Path()))
    _path(str(value.cwd))
    _environment(value.environment, value.role)
    _time(value.deadline)
    _integer(value.maximum_output_bytes, MAX_OUTPUT_BYTES)


@dataclass(frozen=True)
class BootstrapRequest:
    compiler: ExecutableIdentity
    source: ExecutableIdentity
    sdk: SDKIdentity
    cwd: Path
    environment: Tuple[Tuple[str, str], ...]
    deadline: float
    maximum_output_bytes: int
    role: str = field(init=False, default="compiler-bootstrap")

    def __post_init__(self):
        _bootstrap(self)


def _bootstrap(value: BootstrapRequest) -> None:
    _need(type(value) is BootstrapRequest and value.role == "compiler-bootstrap")
    _file_identity(value.compiler, executable=True)
    _file_identity(value.source)
    _sdk_identity(value.sdk)
    _need(type(value.cwd) is type(Path()))
    _path(str(value.cwd))
    _environment(value.environment, value.role)
    _time(value.deadline)
    _integer(value.maximum_output_bytes, BOOTSTRAP_OUTPUT_BYTES, BOOTSTRAP_OUTPUT_BYTES)


@dataclass(frozen=True)
class CommandResult:
    stdout: bytes
    stderr: bytes
    command_status: int
    cleanup_complete: bool

    def __post_init__(self):
        _need(type(self.stdout) is bytes and type(self.stderr) is bytes)
        _need(len(self.stdout) + len(self.stderr) <= MAX_OUTPUT_BYTES)
        _need(type(self.command_status) is int and self.command_status == 0)
        _need(type(self.cleanup_complete) is bool and self.cleanup_complete)


@dataclass(frozen=True)
class ProcessDecision:
    stdout: bytes
    stderr: bytes
    exit_code: int

    def __post_init__(self):
        _need(type(self.stdout) is bytes and type(self.stderr) is bytes)
        _integer(self.exit_code, 255)


@dataclass(frozen=True)
class CommandReceipt:
    outcome: str
    command_status: Optional[int]
    stdout_bytes: int
    stderr_bytes: int
    stdout_sha256: str
    stderr_sha256: str

    def __post_init__(self):
        _receipt(self)


def _receipt(value: CommandReceipt) -> None:
    _need(type(value) is CommandReceipt and type(value.outcome) is str and value.outcome in OUTCOMES)
    _need(value.command_status is None or _status(value.command_status))
    if value.outcome == "success":
        _need(type(value.command_status) is int and value.command_status == 0)
    elif value.outcome == "command-failed":
        _need(value.command_status is not None and value.command_status != 0)
    elif value.outcome == "launch-failed":
        _need(value.command_status is None)
    _integer(value.stdout_bytes, MAX_OUTPUT_BYTES)
    _integer(value.stderr_bytes, MAX_OUTPUT_BYTES)
    _need(value.stdout_bytes + value.stderr_bytes <= MAX_OUTPUT_BYTES)
    _sha(value.stdout_sha256)
    _sha(value.stderr_sha256)


def _fields(value: object, fields: frozenset) -> None:
    _need(type(value) is dict and value.keys() == fields)


def _canonical(value: object, maximum: int) -> bytes:
    chunks = []
    total = 1  # The terminating LF is part of the bound.
    try:
        encoder = json.JSONEncoder(ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
        for piece in encoder.iterencode(value):
            raw = piece.encode("utf-8", errors="strict")
            total += len(raw)
            _need(total <= maximum)
            chunks.append(raw)
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise ProcessFailure("protocol-invalid") from None
    return b"".join(chunks) + b"\n"


def _pairs(pairs):
    _need(len(pairs) <= 64)
    result = {}
    for key, value in pairs:
        _need(key not in result)
        result[key] = value
    return result


def _parse_integer(token: str) -> int:
    _need(len(token.lstrip("-")) <= 20)
    return int(token)


def _parse_float(token: str) -> float:
    _need(len(token) <= 64)
    value = float(token)
    _need(math.isfinite(value))
    return value


def _reject_constant(_token: str):
    raise ProcessFailure("protocol-invalid")


def _parse_canonical_frame(payload: bytes, maximum: int):
    _need(type(payload) is bytes and 0 < len(payload) <= maximum)
    _need(payload.endswith(b"\n") and payload.count(b"\n") == 1)
    try:
        text = payload.decode("utf-8", errors="strict")
        # Bound nested containers before the JSON decoder can build them. Quoted
        # braces/commas do not consume structural limits, including escaped quotes.
        depth = items = 0
        quoted = escaped = False
        for character in text:
            if quoted:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
            elif character in "[{":
                depth += 1
                items += 1
                _need(depth <= MAX_JSON_DEPTH and items <= MAX_JSON_ITEMS)
            elif character in "]}":
                depth -= 1
            elif character in ",:":
                items += 1
                _need(items <= MAX_JSON_ITEMS)
        value = json.loads(text, object_pairs_hook=_pairs, parse_int=_parse_integer,
                           parse_float=_parse_float, parse_constant=_reject_constant)
        _need(_canonical(value, maximum) == payload)
        return value
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise ProcessFailure("protocol-invalid") from None


def _header(context: ProtocolContext, role: str, *, bootstrap: bool) -> dict:
    _context(context, bootstrap=bootstrap)
    value = {"version": 1, "role": role, "session_id": context.session_id,
             "command_id": context.command_id, "trusted_closure_sha256": context.trusted_closure_sha256,
             "profile_id": context.profile_id}
    if not bootstrap:
        value["native_artifact_sha256"] = context.native_artifact_sha256
    return value


def _match_header(value: dict, context: ProtocolContext, role: str, *, bootstrap: bool) -> None:
    expected = _header(context, role, bootstrap=bootstrap)
    _need(type(value["version"]) is int and value["version"] == 1)
    _integer(value["command_id"], MAX_COMMAND_ID, 1)
    for name, expected_value in expected.items():
        _need(type(value[name]) is type(expected_value) and value[name] == expected_value)


def _file_dict(value: ExecutableIdentity) -> dict:
    return {name: getattr(value, name) for name in _FILE_FIELDS}


def _environment_from_wire(value: object) -> Tuple[Tuple[str, str], ...]:
    _need(type(value) is list and len(value) <= MAX_ENVIRONMENT)
    for pair in value:
        _need(type(pair) is list and len(pair) == 2)
        _text(pair[0], 128, nonempty=True)
        _text(pair[1], MAX_ENVIRONMENT_VALUE_BYTES)
    return tuple(tuple(pair) for pair in value)


def _common_request(value, context: ProtocolContext, *, bootstrap: bool) -> dict:
    result = _header(context, value.role, bootstrap=bootstrap)
    result.update(cwd=str(value.cwd), environment=[list(pair) for pair in value.environment],
                  deadline=value.deadline, maximum_output_bytes=value.maximum_output_bytes)
    return result


def encode_request(request: CommandRequest, *, context: ProtocolContext, now: float) -> bytes:
    _command(request)
    _deadline(request.deadline, now, request.role)
    value = _common_request(request, context, bootstrap=False)
    value.update(executable=_file_dict(request.executable), argv=list(request.argv))
    return _canonical(value, MAX_REQUEST_BYTES)


def parse_request(payload: bytes, *, expected: CommandRequest,
                  context: ProtocolContext, now: float) -> CommandRequest:
    _command(expected)
    _context(context, bootstrap=False)
    _deadline(expected.deadline, now, expected.role)
    value = _parse_canonical_frame(payload, MAX_REQUEST_BYTES)
    _fields(value, _OPERATION_FIELDS)
    _match_header(value, context, expected.role, bootstrap=False)
    _fields(value["executable"], _FILE_FIELDS)
    _need(type(value["argv"]) is list and 0 < len(value["argv"]) <= MAX_ARGV)
    for argument in value["argv"]:
        _text(argument, MAX_ARGUMENT_BYTES)
    _path(value["cwd"])
    result = CommandRequest(role=value["role"], executable=ExecutableIdentity(**value["executable"]),
        argv=tuple(value["argv"]), cwd=Path(value["cwd"]),
        environment=_environment_from_wire(value["environment"]), deadline=value["deadline"],
        maximum_output_bytes=value["maximum_output_bytes"])
    _deadline(result.deadline, now, result.role)
    _need(result == expected)
    return result


def encode_bootstrap_request(request: BootstrapRequest, *, context: ProtocolContext, now: float) -> bytes:
    _bootstrap(request)
    _deadline(request.deadline, now, request.role)
    value = _common_request(request, context, bootstrap=True)
    value.update(compiler=_file_dict(request.compiler), source=_file_dict(request.source),
                 sdk={name: getattr(request.sdk, name) for name in _SDK_FIELDS})
    return _canonical(value, MAX_REQUEST_BYTES)


def parse_bootstrap_request(payload: bytes, *, expected: BootstrapRequest,
                            context: ProtocolContext, now: float) -> BootstrapRequest:
    _bootstrap(expected)
    _context(context, bootstrap=True)
    _deadline(expected.deadline, now, expected.role)
    value = _parse_canonical_frame(payload, MAX_REQUEST_BYTES)
    _fields(value, _BOOTSTRAP_FIELDS)
    _match_header(value, context, "compiler-bootstrap", bootstrap=True)
    _fields(value["compiler"], _FILE_FIELDS)
    _fields(value["source"], _FILE_FIELDS)
    _fields(value["sdk"], _SDK_FIELDS)
    _path(value["cwd"])
    result = BootstrapRequest(compiler=ExecutableIdentity(**value["compiler"]),
        source=ExecutableIdentity(**value["source"]), sdk=SDKIdentity(**value["sdk"]),
        cwd=Path(value["cwd"]), environment=_environment_from_wire(value["environment"]),
        deadline=value["deadline"], maximum_output_bytes=value["maximum_output_bytes"])
    _deadline(result.deadline, now, result.role)
    _need(result == expected)
    return result


def _receipt_context(request, context: ProtocolContext, receipt: Optional[CommandReceipt] = None) -> dict:
    bootstrap = type(request) is BootstrapRequest
    if bootstrap:
        _bootstrap(request)
    else:
        _command(request)
    if receipt is not None:
        _receipt(receipt)
        _need(receipt.stdout_bytes + receipt.stderr_bytes <= request.maximum_output_bytes)
    return _header(context, request.role, bootstrap=bootstrap)


def encode_receipt(receipt: CommandReceipt, *, request, context: ProtocolContext) -> bytes:
    value = _receipt_context(request, context, receipt)
    value.update({name: getattr(receipt, name) for name in _RECEIPT_FIELDS})
    return _canonical(value, MAX_RECEIPT_BYTES)


def parse_receipt(payload: bytes, *, request, context: ProtocolContext) -> CommandReceipt:
    header = _receipt_context(request, context)
    value = _parse_canonical_frame(payload, MAX_RECEIPT_BYTES)
    _fields(value, frozenset(header) | _RECEIPT_FIELDS)
    _match_header(value, context, request.role, bootstrap=type(request) is BootstrapRequest)
    result = CommandReceipt(**{name: value[name] for name in _RECEIPT_FIELDS})
    _receipt_context(request, context, result)
    return result
