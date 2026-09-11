"""Qualified process-session boundary; distribution profiles remain inactive."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import tempfile
from types import MappingProxyType
from typing import Callable

from capability_process_protocol import (
    BootstrapRequest,
    CommandReceipt,
    CommandRequest,
    CommandResult,
    ExecutableIdentity,
    ProcessDecision,
    ProcessFailure,
    ProtocolContext,
    MAX_COMMAND_ID,
    MAX_RECEIPT_BYTES,
    MAX_REQUEST_BYTES,
    MAX_OUTPUT_BYTES,
    encode_bootstrap_request,
    encode_receipt,
    encode_request,
    parse_receipt,
)


_DISARMED_ANCHORS = []
_ANCHOR_ATTEMPTS = []
_WORKER_COMMANDS = []
_SHA256 = re.compile(r"[0-9a-f]{64}")
_PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")
_PACKAGE_MEMBERS = {
    "bats_evidence.py": "python-source", "bats_inventory.py": "python-source",
    "capability_policy.py": "python-source", "capability_process.py": "python-source",
    "capability_process_native.c": "native-source",
    "capability_process_profiles.json": "profile-data",
    "capability_process_protocol.py": "python-source", "capability_schema.py": "python-source",
}
_MANIFEST_NAME = "capability_package_manifest.json"


def _unavailable(reason="process-unavailable", cleanup="not-needed"):
    return ProcessFailure(reason=reason, command_status=None,
                          cleanup_disposition=cleanup,
                          session_disposition="poisoned")


class _PreparationBudget:
    def __init__(self, captured_clock: Callable[[], float], started: float,
                 deadline: float):
        self._captured_clock = captured_clock
        self._started = started
        self._deadline = deadline
        self._consumed = False

    def _consume(self):
        if self._consumed:
            raise _unavailable()
        self._consumed = True
        if (not callable(self._captured_clock)
                or not _valid_time(self._started)
                or not _valid_time(self._deadline)
                or self._deadline != self._started + 58.0):
            raise _unavailable()
        try:
            now = self._captured_clock()
        except Exception:
            raise _unavailable() from None
        if not _valid_time(now) or not self._started <= now < self._deadline:
            raise _unavailable()
        return self._captured_clock, self._started, self._deadline


@dataclass(frozen=True)
class TrustedRunnerRoot:
    path: Path
    expected_manifest_sha256: str
    budget: _PreparationBudget


@dataclass(frozen=True)
class TrustedEntryContext:
    trusted_root: TrustedRunnerRoot
    expected_manifest_sha256: str
    profile_id: str


def require_trusted_entry_context(value: object) -> TrustedEntryContext:
    if (type(value) is not TrustedEntryContext
            or type(value.trusted_root) is not TrustedRunnerRoot
            or not isinstance(value.trusted_root.path, Path)
            or not value.trusted_root.path.is_absolute()
            or type(value.expected_manifest_sha256) is not str
            or _SHA256.fullmatch(value.expected_manifest_sha256) is None
            or value.trusted_root.expected_manifest_sha256 != value.expected_manifest_sha256
            or type(value.profile_id) is not str
            or _PROFILE_ID.fullmatch(value.profile_id) is None
            or type(value.trusted_root.budget) is not _PreparationBudget
            or value.trusted_root.budget._consumed):
        raise _unavailable()
    return value


def require_process_session(value: object) -> QualifiedProcessSession:
    if (type(value) is not QualifiedProcessSession
            or getattr(value, "_prepared", False) is not True
            or getattr(value, "_state", None) not in {"ready", "poisoned"}):
        raise _unavailable()
    return value


def _valid_time(value):
    return type(value) is float and math.isfinite(value) and value >= 0.0


def _disarm_anchor(anchor):
    """Revoke bookkeeping, not process status or ownership-loss evidence.

    The admitted CPython subprocess source must qualify this private flag's
    destructor behavior. Strong retention prevents normal __del__/_active entry;
    failed or revoked wait authority never becomes a fabricated returncode.
    """
    if any(item is anchor for item in _DISARMED_ANCHORS):
        return
    _DISARMED_ANCHORS.append(anchor)
    active = getattr(subprocess, "_active", None)
    absent = type(active) is list and not any(item is anchor for item in active)
    anchor._child_created = False
    if not absent:
        raise _unavailable("cleanup-failed", "failed")


@dataclass
class _AnchorAttempt:
    anchor: object
    outcome: str = "active"


def _cleanup_anchor(anchor, *, deadline, clock, observe):
    """Signal a proven live anchor before its one bounded wait.

    Only a qualified runtime's exclusively retained direct child may reach this
    helper. Tests replace those boundaries explicitly; a PID is not authority.
    """
    return _consume_anchor(anchor, lambda: _cleanup_consumed_anchor(
        anchor, deadline=deadline, clock=clock, observe=observe))


def _consume_anchor(anchor, operation):
    if (any(item is anchor for item in _DISARMED_ANCHORS)
            or any(item.anchor is anchor for item in _ANCHOR_ATTEMPTS)):
        raise _unavailable("ownership-lost", "authority-lost")
    # Consume the exact wrapper before the first observation. Strong retention
    # prevents object-identity reuse, and neither failure nor success restores
    # observation, signalling, or waiting authority.
    attempt = _AnchorAttempt(anchor)
    _ANCHOR_ATTEMPTS.append(attempt)
    try:
        status = operation()
    except BaseException:
        attempt.outcome = "failed"
        _disarm_anchor(anchor)
        raise
    attempt.outcome = "complete"
    return status


def _cleanup_bootstrap_anchor(anchor, *, deadline, clock):
    """Preparing-only qualified-reset ownership, without native observation.

    The caller must exclusively retain this unpolled direct child from its
    qualified launch. Operational requests cannot select this cleanup route.
    """
    def cleanup():
        if anchor.returncode is not None:
            raise _unavailable("ownership-lost", "authority-lost")
        signalled = False
        try:
            os.killpg(anchor.pid, signal.SIGKILL)
            signalled = True
        except OSError:
            pass
        return _reap_consumed_anchor(anchor, deadline=deadline, clock=clock,
                                     signalled=signalled, lost=False)
    return _consume_anchor(anchor, cleanup)


def _cleanup_consumed_anchor(anchor, *, deadline, clock, observe):
    lost = False
    try:
        observed = observe(anchor.pid)
    except ChildProcessError:
        _disarm_anchor(anchor)
        raise _unavailable("ownership-lost", "authority-lost") from None
    except Exception:
        _disarm_anchor(anchor)
        raise _unavailable("ownership-lost", "authority-lost") from None
    if (type(observed) is not tuple or len(observed) != 4
            or any(type(item) is not int for item in observed)):
        _disarm_anchor(anchor)
        raise _unavailable("ownership-lost", "authority-lost")
    state, observed_pid, kind, code = observed
    if observed == (0, 0, 0, 0):
        signalled = False
        try:
            os.killpg(anchor.pid, signal.SIGKILL)
            signalled = True
        except OSError:
            pass
    elif (state == 1 and observed_pid == anchor.pid
          and ((kind == 1 and 0 <= code <= 255)
               or (kind in (2, 3) and 1 <= code <= 31))):
        # Terminal direct child retains sole-reap authority, never group signal.
        signalled = False
        lost = True
    else:
        _disarm_anchor(anchor)
        raise _unavailable("ownership-lost", "authority-lost")
    return _reap_consumed_anchor(anchor, deadline=deadline, clock=clock,
                                 signalled=signalled, lost=lost)


def _reap_consumed_anchor(anchor, *, deadline, clock, signalled, lost):
    try:
        started = clock()
        if not _valid_time(started) or not _valid_time(deadline):
            raise ValueError()
        remaining = min(2.0, deadline + 2.0 - started)
        if remaining <= 0.0:
            raise ValueError()
        status = anchor.wait(timeout=remaining)
        finished = clock()
        if (not _valid_time(finished) or finished < started
                or finished >= min(started + 2.0, deadline + 2.0)):
            raise ValueError()
    except Exception:
        _disarm_anchor(anchor)
        raise _unavailable("cleanup-failed", "failed") from None
    if lost:
        _disarm_anchor(anchor)
        raise _unavailable("ownership-lost", "authority-lost")
    if not signalled or type(status) is not int or status != -int(signal.SIGKILL):
        # In particular, CPython's synthesized ECHILD status zero is not a reap.
        _disarm_anchor(anchor)
        raise _unavailable("cleanup-failed", "failed")
    return status


@dataclass(frozen=True)
class _VerifiedPackage:
    root: Path
    sha256: str
    members: object
    identities: object
    directory_identity: tuple


@dataclass(frozen=True)
class _SelectedProfile:
    id: str
    platform: object
    runtime: object
    projection: object
    compiler_arguments: tuple
    executables: object
    compiler: ExecutableIdentity
    linker: ExecutableIdentity


def _bounded_clock(clock, deadline):
    previous = None

    def checkpoint():
        nonlocal previous
        try:
            now = clock()
        except Exception:
            raise _unavailable("deadline") from None
        if (not _valid_time(now) or not _valid_time(deadline) or now >= deadline
                or (previous is not None and now < previous)):
            raise _unavailable("deadline")
        previous = now
        return deadline - now

    return checkpoint


def _json_object(raw, maximum):
    if type(raw) is not bytes or not 0 < len(raw) <= maximum:
        raise _unavailable("identity-drift")
    try:
        text = raw.decode("utf-8", errors="strict")
        # Bound structure before the decoder allocates nested containers.
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
                if depth > 16 or items > 32768:
                    raise ValueError()
            elif character in "]}":
                depth -= 1
            elif character in ",:":
                items += 1
                if items > 32768:
                    raise ValueError()

        def pairs(entries):
            result = {}
            for name, value in entries:
                if name in result:
                    raise ValueError()
                result[name] = value
            return result

        def integer(token):
            if len(token.lstrip("-")) > 20:
                raise ValueError()
            return int(token)

        def floating(token):
            if len(token) > 64:
                raise ValueError()
            value = float(token)
            if not math.isfinite(value):
                raise ValueError()
            return value

        def constant(_token):
            raise ValueError()

        result = json.loads(text, object_pairs_hook=pairs, parse_int=integer,
                            parse_float=floating, parse_constant=constant)
        if type(result) is not dict:
            raise ValueError()
        return result
    except (UnicodeError, ValueError, RecursionError):
        raise _unavailable("identity-drift") from None


def _read_regular_at(parent, name, maximum, checkpoint):
    checkpoint()
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= maximum:
        raise _unavailable("identity-drift")
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=parent)
    try:
        checkpoint()
        if _stat_key(os.fstat(descriptor)) != _stat_key(before):
            raise _unavailable("identity-drift")
        result = bytearray()
        while True:
            checkpoint()
            data = os.read(descriptor, min(65536, maximum - len(result) + 1))
            checkpoint()
            if not data:
                break
            result.extend(data)
            if len(result) > maximum:
                raise _unavailable("identity-drift")
        if (len(result) != before.st_size
                or _stat_key(os.fstat(descriptor)) != _stat_key(before)
                or _stat_key(os.stat(name, dir_fd=parent, follow_symlinks=False)) != _stat_key(before)):
            raise _unavailable("identity-drift")
    finally:
        _close_descriptor(descriptor)
    checkpoint()
    return bytes(result), before


def _identity(path, payload, info):
    return ExecutableIdentity(str(path), hashlib.sha256(payload).hexdigest(),
        info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_uid, info.st_gid,
        info.st_mtime_ns, info.st_ctime_ns)


def _verify_package(trusted_root, *, deadline, clock):
    checkpoint = _bounded_clock(clock, deadline)
    checkpoint()
    if (type(trusted_root) is not TrustedRunnerRoot
            or type(trusted_root.path) is not type(Path())
            or not trusted_root.path.is_absolute()
            or type(trusted_root.expected_manifest_sha256) is not str
            or _SHA256.fullmatch(trusted_root.expected_manifest_sha256) is None):
        raise _unavailable("identity-drift")
    root = trusted_root.path
    descriptor = None
    try:
        if root.resolve(strict=True) != root:
            raise _unavailable("identity-drift")
        checkpoint()
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        original = os.fstat(descriptor)
        checkpoint()
        names = set()
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) >= 9:
                    raise _unavailable("identity-drift")
                names.add(entry.name)
                checkpoint()
        if names != set(_PACKAGE_MEMBERS) | {_MANIFEST_NAME}:
            raise _unavailable("identity-drift")
        raw, manifest_info = _read_regular_at(descriptor, _MANIFEST_NAME, 64 * 1024, checkpoint)
        if hashlib.sha256(raw).hexdigest() != trusted_root.expected_manifest_sha256:
            raise _unavailable("identity-drift")
        checkpoint()
        manifest = _json_object(raw, 64 * 1024)
        if (set(manifest) != {"schema_version", "members"}
                or type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1
                or type(manifest["members"]) is not list or len(manifest["members"]) != 8):
            raise _unavailable("identity-drift")
        total = 0
        for row, expected in zip(manifest["members"], sorted(_PACKAGE_MEMBERS)):
            if (type(row) is not dict or set(row) != {"path", "kind", "size", "sha256"}
                    or row["path"] != expected or row["kind"] != _PACKAGE_MEMBERS[expected]
                    or type(row["size"]) is not int or not 0 <= row["size"] <= 1024 * 1024
                    or type(row["sha256"]) is not str or _SHA256.fullmatch(row["sha256"]) is None):
                raise _unavailable("identity-drift")
            total += row["size"]
            if total > 8 * 1024 * 1024:
                raise _unavailable("identity-drift")
        members = {}
        identities = {_MANIFEST_NAME: _identity(root / _MANIFEST_NAME, raw, manifest_info)}
        for row in manifest["members"]:
            payload, info = _read_regular_at(descriptor, row["path"], row["size"], checkpoint)
            record = _identity(root / row["path"], payload, info)
            checkpoint()
            if record.size != row["size"] or record.sha256 != row["sha256"]:
                raise _unavailable("identity-drift")
            members[row["path"]] = payload
            identities[row["path"]] = record
        # Use a fresh directory description so the second scan does not
        # depend on the first iterator's directory offset.
        inventory = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=descriptor)
        try:
            names = set()
            with os.scandir(inventory) as entries:
                for entry in entries:
                    if len(names) >= 9:
                        raise _unavailable("identity-drift")
                    names.add(entry.name)
                    checkpoint()
            if names != set(_PACKAGE_MEMBERS) | {_MANIFEST_NAME}:
                raise _unavailable("identity-drift")
        finally:
            _close_descriptor(inventory)
        if (_stat_key(os.fstat(descriptor)) != _stat_key(original)
                or _stat_key(root.lstat()) != _stat_key(original)):
            raise _unavailable("identity-drift")
        checkpoint()
        result = _VerifiedPackage(root, trusted_root.expected_manifest_sha256,
            MappingProxyType(members), MappingProxyType(identities), _directory_key(original))
    except ProcessFailure:
        raise
    except (OSError, ValueError, TypeError):
        raise _unavailable("identity-drift") from None
    finally:
        if descriptor is not None:
            _close_descriptor(descriptor)
    checkpoint()
    return result


def _select_profile(package, profile_id, *, deadline, clock):
    checkpoint = _bounded_clock(clock, deadline)
    checkpoint()
    if (type(package) is not _VerifiedPackage or type(profile_id) is not str
            or _PROFILE_ID.fullmatch(profile_id) is None):
        raise _unavailable()
    registry = _json_object(package.members["capability_process_profiles.json"], 1024 * 1024)
    if (set(registry) != {"schema_version", "profiles"}
            or type(registry["schema_version"]) is not int or registry["schema_version"] != 1
            or type(registry["profiles"]) is not list or len(registry["profiles"]) > 16):
        raise _unavailable()
    selected = None
    names = set()
    fields = {"id", "status", "platform", "runtime", "projection", "compiler_arguments", "executables"}
    for row in registry["profiles"]:
        if (type(row) is not dict or set(row) != fields or type(row["id"]) is not str
                or _PROFILE_ID.fullmatch(row["id"]) is None or row["id"] in names
                or type(row["status"]) is not str or row["status"] not in {"qualified", "inactive"}
                or any(type(row[name]) is not dict for name in ("platform", "runtime", "projection"))
                or type(row["compiler_arguments"]) is not list
                or not 0 < len(row["compiler_arguments"]) <= 256
                or any(type(arg) is not str or "\x00" in arg or len(arg.encode("utf-8")) > 4096
                       for arg in row["compiler_arguments"])
                or type(row["executables"]) is not dict
                or set(row["executables"]) != {"git", "swift", "compiler", "linker"}):
            raise _unavailable()
        names.add(row["id"])
        tools = {}
        try:
            for name, record in row["executables"].items():
                if type(record) is not dict:
                    raise TypeError()
                tool = ExecutableIdentity(**record)
                if not tool.mode & 0o111:
                    raise ValueError()
                tools[name] = tool
        except (TypeError, ValueError, ProcessFailure):
            raise _unavailable() from None
        if row["id"] == profile_id and row["status"] == "qualified":
            metadata = _admit_runtime_metadata(row["platform"], row["runtime"],
                                               deadline=deadline, clock=clock)
            selected = _SelectedProfile(profile_id, metadata.platform,
                metadata.runtime, _freeze_data(row["projection"]),
                tuple(row["compiler_arguments"]), MappingProxyType({
                    "git": tools["git"], "swift-test": tools["swift"],
                    "swift-build": tools["swift"], "swift-bin-path": tools["swift"]}),
                tools["compiler"], tools["linker"])
        checkpoint()
    if selected is None:
        raise _unavailable()
    checkpoint()
    return selected


def _freeze_data(value):
    if type(value) is dict:
        return MappingProxyType({name: _freeze_data(item) for name, item in value.items()})
    if type(value) is list:
        return tuple(_freeze_data(item) for item in value)
    return value


@dataclass(frozen=True)
class _RuntimeMetadata:
    """Detached descriptors only; these contain no captured runtime authority."""
    platform: object
    runtime: object


def _bound_runtime_metadata(value, checkpoint):
    """Apply the profile JSON ceilings before copying or expanding descriptors."""
    size = items = 0
    ancestors = set()

    def charge(amount):
        nonlocal size
        size += amount
        if size > 1024 * 1024:
            raise _unavailable()

    def visit(item, depth):
        nonlocal items
        checkpoint()
        items += 1
        if items > 32768:
            raise _unavailable()
        kind = type(item)
        if kind in (dict, list):
            if depth >= 16 or len(item) > 32768 or id(item) in ancestors:
                raise _unavailable()
            ancestors.add(id(item))
            charge(2 + max(0, len(item) - 1))
            if kind is dict:
                for key, child in item.items():
                    if type(key) is not str:
                        raise _unavailable()
                    visit(key, depth + 1)
                    charge(1)
                    visit(child, depth + 1)
            else:
                for child in item:
                    visit(child, depth + 1)
            ancestors.remove(id(item))
        elif kind is str:
            # Count compact UTF-8 JSON without first allocating its escaped form.
            if len(item) > 1024 * 1024 - size:
                raise _unavailable()
            charge(2)
            for index, character in enumerate(item):
                if index % 256 == 0:
                    checkpoint()
                code = ord(character)
                if 0xD800 <= code <= 0xDFFF:
                    raise _unavailable()
                charge(2 if character in '\\"\b\f\n\r\t' else
                       6 if code < 32 else 1 if code < 128 else
                       2 if code < 2048 else 3 if code < 65536 else 4)
        elif item is None:
            charge(4)
        elif kind is bool:
            charge(4 if item else 5)
        elif kind is int:
            if not -(10**20) < item < 10**20:
                raise _unavailable()
            charge(len(str(item)))
        elif kind is float and math.isfinite(item):
            charge(len(repr(item)))
        else:
            raise _unavailable()

    visit(value, 0)
    checkpoint()


def _admit_runtime_metadata(platform, runtime, *, deadline, clock):
    """Validate finite metadata without imports, file reads, reset or loading.

    Existing-loader source/cache selection and image/body observations still need
    actual-process qualification. A well-formed row cannot activate a profile.
    """
    checkpoint = _bounded_clock(clock, deadline)
    checkpoint()
    _bound_runtime_metadata({"platform": platform, "runtime": runtime}, checkpoint)

    def need(condition):
        if not condition:
            raise _unavailable()

    def record(value, fields):
        need(type(value) is dict and set(value) == set(fields.split()))

    def integer(value, minimum=0, maximum=2**64 - 1):
        need(type(value) is int and minimum <= value <= maximum)

    def text(value):
        need(type(value) is str and bool(value) and "\x00" not in value)

    def pattern(value, expression):
        text(value)
        need(re.fullmatch(expression, value) is not None)

    def path(value):
        text(value)
        need(value.startswith("/") and (value == "/" or all(
            part not in ("", ".", "..") for part in value[1:].split("/"))))

    def unique(values):
        need(type(values) is list and all(type(value) is str for value in values))
        need(len(values) == len(set(values)))

    def uuid(value):
        pattern(value, r"[0-9a-f]{32}")

    def module_name(value):
        pattern(value, r"[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*")

    record(platform, "schema_version system architecture product_version build_version apple_base")
    integer(platform["schema_version"], 1, 1)
    need(platform["system"] == "Darwin" and platform["architecture"] == "arm64")
    pattern(platform["product_version"], r"[0-9]+(?:\.[0-9]+){1,2}")
    pattern(platform["build_version"], r"[0-9]+[A-Z][0-9]+[a-z]?")
    base = platform["apple_base"]
    record(base, "assumption cache_uuid images")
    need(base["assumption"] == "selected-apple-system")
    uuid(base["cache_uuid"])
    need(type(base["images"]) is list and bool(base["images"]))
    system_names = set()
    for image in base["images"]:
        record(image, "install_name uuid file_type")
        path(image["install_name"])
        need(image["install_name"].startswith(("/usr/lib/", "/System/Library/")))
        need(image["install_name"] not in system_names)
        system_names.add(image["install_name"])
        uuid(image["uuid"])
        integer(image["file_type"], 6, 6)

    record(runtime, "schema_version implementation startup images bindings files search_paths "
           "absent_inputs external_entry_module modules popen limits")
    integer(runtime["schema_version"], 1, 1)
    implementation = runtime["implementation"]
    record(implementation, "name version pointer_bits byteorder cache_tag bytecode_magic")
    need(implementation["name"] == "cpython")
    version = implementation["version"]
    need(type(version) is list and len(version) == 3)
    for component in version:
        integer(component)
    need(version[:2] == [3, 9])
    integer(implementation["pointer_bits"], 64, 64)
    need(implementation["byteorder"] == "little" and implementation["cache_tag"] == "cpython-39")
    pattern(implementation["bytecode_magic"], r"[0-9a-f]{8}")
    record(runtime["startup"], "isolated no_site dont_write_bytecode ignore_environment optimize")
    for name, value in runtime["startup"].items():
        integer(value, 0 if name == "optimize" else 1, 0 if name == "optimize" else 1)

    bindings = runtime["bindings"]
    record(bindings, "clock reset")
    record(bindings["clock"], "module name constant value")
    need(bindings["clock"] == {"module": "time", "name": "clock_gettime",
                              "constant": "CLOCK_UPTIME_RAW", "value": 8})
    integer(bindings["clock"]["value"], 8, 8)
    reset = bindings["reset"]
    record(reset, "module name getter_offset wrapper_offset helper_offset")
    need(reset["module"] == "_signal" and reset["name"] == "signal")
    for name in ("getter_offset", "wrapper_offset", "helper_offset"):
        integer(reset[name])

    limits = runtime["limits"]
    record(limits, "module_count file_count per_file_bytes aggregate_file_bytes "
           "code_nodes code_depth code_bytes image_command_bytes")
    for value in limits.values():
        integer(value, 1)
    need(type(runtime["files"]) is list and 0 < len(runtime["files"]) <= limits["file_count"])
    files, file_paths = {}, set()
    total = 0
    for row in runtime["files"]:
        checkpoint()
        record(row, "id identity")
        pattern(row["id"], r"[a-z0-9][a-z0-9._-]*")
        need(row["id"] not in files and type(row["identity"]) is dict)
        try:
            identity = ExecutableIdentity(**row["identity"])
        except (TypeError, ValueError, ProcessFailure):
            raise _unavailable() from None
        need(identity.path not in file_paths)
        file_paths.add(identity.path)
        need(identity.size <= limits["per_file_bytes"])
        total += identity.size
        need(total <= limits["aggregate_file_bytes"])
        files[row["id"]] = identity

    def file_reference(value):
        need(type(value) is str and value in files)

    images = runtime["images"]
    record(images, "launcher main framework")
    image_files, image_identities = set(), set()
    for name, image in images.items():
        record(image, "file" if name == "launcher" else "file uuid file_type architecture")
        file_reference(image["file"])
        need(image["file"] not in image_files)
        image_files.add(image["file"])
        identity = files[image["file"]]
        need((identity.device, identity.inode) not in image_identities)
        image_identities.add((identity.device, identity.inode))
        if name != "framework":
            need(bool(identity.mode & 0o111))
        if name != "launcher":
            uuid(image["uuid"])
            integer(image["file_type"], 2 if name == "main" else 6, 2 if name == "main" else 6)
            need(image["architecture"] == platform["architecture"])
    for field in ("search_paths", "absent_inputs"):
        unique(runtime[field])
        for value in runtime[field]:
            path(value)
    need(bool(runtime["search_paths"]))
    absent = set(runtime["absent_inputs"])
    for file_path in file_paths:
        # Compare complete components, including the root, without multiplying
        # the file count by the number of absence observations.
        ancestor = file_path
        while True:
            need(ancestor not in absent)
            if ancestor == "/":
                break
            ancestor = ancestor.rpartition("/")[0] or "/"
        checkpoint()
    need(runtime["external_entry_module"] == "__main__")
    need(type(runtime["modules"]) is list and 0 < len(runtime["modules"]) <= limits["module_count"])
    modules, names = {}, {runtime["external_entry_module"]}
    common = "name kind spec_name aliases "
    fields = {
        "builtin": "registry_name", "frozen": "registry_name file_alias",
        "source": "loader selected_input source cache package_member",
        "extension": "file uuid dependencies"}
    for row in runtime["modules"]:
        checkpoint()
        need(type(row) is dict and type(row.get("kind")) is str and row["kind"] in fields)
        kind = row["kind"]
        record(row, common + fields[kind])
        module_name(row["name"])
        module_name(row["spec_name"])
        unique(row["aliases"])
        for alias in [row["name"]] + row["aliases"]:
            module_name(alias)
            need(alias not in names)
            names.add(alias)
        modules[row["name"]] = row
        if kind in ("builtin", "frozen"):
            module_name(row["registry_name"])
            need(row["spec_name"] == row["registry_name"])
            if kind == "frozen" and row["file_alias"] is not None:
                file_reference(row["file_alias"])
        elif kind == "source":
            need(row["spec_name"] == row["name"])
            if row["loader"] == "verified-package-buffer":
                need(row["selected_input"] == "package-buffer" and row["source"] is None
                     and row["cache"] is None and type(row["package_member"]) is str
                     and row["package_member"] == row["name"] + ".py"
                     and _PACKAGE_MEMBERS.get(row["package_member"]) == "python-source")
            else:
                need(row["loader"] == "SourceFileLoader" and row["package_member"] is None
                     and row["selected_input"] in ("source", "cache"))
                file_reference(row["source"])
                if row["selected_input"] == "cache":
                    file_reference(row["cache"])
                    need(row["cache"] != row["source"])
                else:
                    need(row["cache"] is None)
        else:
            need(row["spec_name"] == row["name"])
            file_reference(row["file"])
            uuid(row["uuid"])
            unique(row["dependencies"])
            for dependency in row["dependencies"]:
                file_reference(dependency)
                need(dependency != row["file"])
    for name in ("time", "_signal"):
        need(name in modules and modules[name]["kind"] == "builtin"
             and modules[name]["registry_name"] == name)
    popen = runtime["popen"]
    record(popen, "module class destructor source active_name expected_active_count")
    need(popen["module"] == "subprocess" and popen["class"] == "Popen"
         and popen["destructor"] == "__del__" and popen["active_name"] == "_active")
    integer(popen["expected_active_count"], 0, 0)
    file_reference(popen["source"])
    need("subprocess" in modules and modules["subprocess"]["kind"] == "source"
         and modules["subprocess"]["source"] == popen["source"])
    result = _RuntimeMetadata(_freeze_data(platform), _freeze_data(runtime))
    checkpoint()
    return result


def _qualify_runtime(profile, *, deadline, clock):
    raise _unavailable()


def _build_projection(package, profile, directory, *, deadline, clock):
    raise _unavailable()


def _bootstrap_native(session, projection, *, deadline):
    raise _unavailable()


def _revalidate_session(session, *, deadline):
    raise _unavailable()


@dataclass(frozen=True)
class _FixedCommand:
    executable: ExecutableIdentity
    argv: tuple
    cwd: Path
    environment: tuple
    deadline: float
    maximum_output_bytes: int

    def __post_init__(self):
        _check_launch_data(self.executable, self.argv, self.cwd, self.environment)
        if (not _valid_time(self.deadline) or type(self.maximum_output_bytes) is not int
                or not 0 <= self.maximum_output_bytes <= MAX_OUTPUT_BYTES):
            raise _unavailable("protocol-invalid")


@dataclass(frozen=True)
class _WorkerLaunch:
    executable: ExecutableIdentity
    argv: tuple
    cwd: Path
    environment: tuple

    def __post_init__(self):
        _check_launch_data(self.executable, self.argv, self.cwd, self.environment)


def _check_launch_data(executable, argv, cwd, environment):
    def text(value, maximum):
        if type(value) is not str or len(value) > maximum or "\x00" in value:
            raise _unavailable("protocol-invalid")
        try:
            if len(value.encode("utf-8")) > maximum:
                raise _unavailable("protocol-invalid")
        except UnicodeError:
            raise _unavailable("protocol-invalid") from None
    if (type(executable) is not ExecutableIdentity or not executable.mode & 0o111
            or type(argv) is not tuple or not 0 < len(argv) <= 256
            or argv[0] != executable.path or type(cwd) is not type(Path())
            or not cwd.is_absolute() or type(environment) is not tuple or len(environment) > 128):
        raise _unavailable("protocol-invalid")
    text(str(cwd), 4096)
    for argument in argv:
        text(argument, 4096)
    names = set()
    for row in environment:
        if type(row) is not tuple or len(row) != 2:
            raise _unavailable("protocol-invalid")
        key, value = row
        text(key, 128)
        text(value, 8192)
        if not key or "=" in key or key in names:
            raise _unavailable("protocol-invalid")
        names.add(key)


@dataclass
class _WorkerTransport:
    directory: Path
    directory_identity: tuple
    request_fd: object = None
    receipt_fd: object = None
    receipt_write_fd: object = None
    anchor: object = None


def _close_transport_fields(transport, names):
    failed = False
    for name in names:
        descriptor = getattr(transport, name, None)
        if descriptor is not None:
            setattr(transport, name, None)
            try:
                _close_descriptor(descriptor)
            except ProcessFailure:
                failed = True
    if failed:
        raise _unavailable("cleanup-failed", "failed")


def _close_worker_transport(transport):
    _close_transport_fields(transport, ("request_fd", "receipt_write_fd", "receipt_fd"))


def _open_worker_transport(frame, directory, *, checkpoint):
    checkpoint()
    if (type(frame) is not bytes or not 0 < len(frame) <= MAX_REQUEST_BYTES
            or not frame.endswith(b"\n") or frame.count(b"\n") != 1):
        raise _unavailable("protocol-invalid")
    parent = writer = None
    transport = None
    failure = None
    try:
        parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        info = os.fstat(parent)
        if (info.st_mode & 0o777 != 0o700 or info.st_uid != os.getuid()
                or _directory_key(directory.lstat()) != _directory_key(info)):
            raise _unavailable("identity-drift")
        transport = _WorkerTransport(directory, _directory_key(info))
        checkpoint()
        writer = os.open("request.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        os.fchmod(writer, 0o600)
        offset = 0
        while offset < len(frame):
            checkpoint()
            try:
                written = os.write(writer, frame[offset:])
            except InterruptedError:
                continue
            if written <= 0:
                raise _unavailable("protocol-invalid")
            offset += written
            checkpoint()
        written_info = os.fstat(writer)
        owned, writer = writer, None
        _close_descriptor(owned)
        checkpoint()
        transport.request_fd = os.open("request.json", os.O_RDONLY | os.O_NOFOLLOW
                                       | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        if _stat_key(os.fstat(transport.request_fd)) != _stat_key(written_info):
            raise _unavailable("identity-drift")
        checkpoint()
        transport.receipt_fd, transport.receipt_write_fd = os.pipe()
        for descriptor in (transport.receipt_fd, transport.receipt_write_fd):
            os.set_blocking(descriptor, False)
            os.set_inheritable(descriptor, False)
        checkpoint()
        if _directory_key(directory.lstat()) != transport.directory_identity:
            raise _unavailable("identity-drift")
    except ProcessFailure as caught:
        failure = caught
    except Exception:
        failure = _unavailable()
    finally:
        for descriptor in (writer, parent):
            if descriptor is not None:
                try:
                    _close_descriptor(descriptor)
                except ProcessFailure as caught:
                    failure = caught
    try:
        if failure is not None:
            raise failure
        checkpoint()
    except BaseException:
        if transport is not None:
            _close_worker_transport(transport)
        raise
    return transport


def _start_retained_worker(transport, launch, *, checkpoint):
    checkpoint()
    if (type(transport) is not _WorkerTransport or type(launch) is not _WorkerLaunch
            or transport.anchor is not None or transport.request_fd is None
            or transport.receipt_write_fd is None):
        raise _unavailable("protocol-invalid")
    try:
        # The caller retains transport before entering this function. No clock,
        # close or cancellation observation may intervene after Popen returns.
        transport.anchor = subprocess.Popen(
            launch.argv + ("--request-fd", str(transport.request_fd),
                           "--receipt-fd", str(transport.receipt_write_fd)),
            executable=launch.executable.path, cwd=launch.cwd,
            env=dict(launch.environment), stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True, pass_fds=(transport.request_fd, transport.receipt_write_fd),
            start_new_session=True, restore_signals=True)
        checkpoint()
        _close_transport_fields(transport, ("request_fd", "receipt_write_fd"))
        checkpoint()
    except ProcessFailure:
        raise
    except Exception:
        raise _unavailable() from None


def _worker_launch(session):
    # A fixed invocation must come from qualified loaded runtime/entry bindings.
    # No candidate path or metadata-only profile can supply that authority.
    raise _unavailable()


def _bootstrap_worker_launch(session, *, deadline):
    # The real qualifier must supply captured live reset/launcher bindings.
    raise _unavailable()


def _spawn_worker(session, request, context, directory):
    if session._state != "command-active" or not session._prepared:
        raise _unavailable()
    checkpoint = lambda: session._checkpoint(request.deadline)
    checkpoint()
    frame = encode_request(request, context=context, now=session.clock())
    launch = _worker_launch(session)
    if type(launch) is not _WorkerLaunch:
        raise _unavailable()
    checkpoint()
    transport = _open_worker_transport(frame, directory, checkpoint=checkpoint)
    session._active_transport = transport
    try:
        _start_retained_worker(transport, launch, checkpoint=checkpoint)
    finally:
        session._active_anchor = transport.anchor
    return transport


def _spawn_bootstrap_worker(session, request, context, directory, *, deadline):
    if (type(session) is not QualifiedProcessSession or session._state != "preparing"
            or session._prepared or getattr(session, "_bootstrap_consumed", False)
            or type(request) is not BootstrapRequest or request.deadline != deadline
            or getattr(session, "_bootstrap_deadline", None) != deadline
            or getattr(session, "_native", None) is not None
            or context.session_id != session._session_id
            or context.profile_id != session._profile_id
            or context.trusted_closure_sha256 != session._package.sha256):
        raise _unavailable()
    session._bootstrap_consumed = True
    try:
        checkpoint = lambda: session._checkpoint(deadline)
        checkpoint()
        frame = encode_bootstrap_request(request, context=context, now=session.clock())
        launch = _bootstrap_worker_launch(session, deadline=deadline)
        if type(launch) is not _WorkerLaunch:
            raise _unavailable()
        checkpoint()
        transport = _open_worker_transport(frame, directory, checkpoint=checkpoint)
        session._active_transport = transport
        try:
            _start_retained_worker(transport, launch, checkpoint=checkpoint)
        finally:
            session._active_anchor = transport.anchor
        return transport
    except BaseException:
        session._poison()
        raise


def _capture_worker_command(command, directory, *, request_fd, receipt_fd, checkpoint):
    checkpoint()
    if type(command) is not _FixedCommand:
        raise _unavailable("protocol-invalid")
    try:
        os.set_inheritable(request_fd, False)
        os.set_inheritable(receipt_fd, False)
        checkpoint()
    except ProcessFailure:
        raise
    except OSError:
        raise _unavailable() from None
    parent = None
    captures = {}
    streams = []
    child = None
    counts = {"stdout": 0, "stderr": 0}
    hashes = {name: hashlib.sha256() for name in counts}
    outcome, status = "success", None
    failure = None
    try:
        parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        owner = os.fstat(parent)
        if (owner.st_mode & 0o777 != 0o700 or owner.st_uid != os.getuid()
                or _directory_key(directory.lstat()) != _directory_key(owner)):
            raise _unavailable("identity-drift")
        for name in counts:
            checkpoint()
            descriptor = os.open(name + ".bin", os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
            captures[name] = descriptor
            os.fchmod(descriptor, 0o600)
        checkpoint()
        try:
            child = subprocess.Popen(command.argv, executable=command.executable.path,
                cwd=command.cwd, env=dict(command.environment), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
                start_new_session=False, restore_signals=True, bufsize=0)
            # Retain before any observation, including cancellation after spawn.
            # A failure with no reaped result leaves cleanup to the outer group.
            _WORKER_COMMANDS.append(child)
        except OSError:
            outcome = "launch-failed"
        if child is not None:
            streams = [child.stdout, child.stderr]
            checkpoint()
            with selectors.DefaultSelector() as selector:
                for name, stream in zip(counts, streams):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, name)
                while selector.get_map() and outcome == "success":
                    remaining_time = checkpoint()
                    ready = selector.select(timeout=min(0.1, remaining_time))
                    checkpoint()
                    # One bounded read per ready stream on each iteration.
                    for key, _ in ready:
                        name = key.data
                        allowance = command.maximum_output_bytes - sum(counts.values())
                        checkpoint()
                        try:
                            chunk = os.read(key.fd, min(65536, allowance + 1))
                        except (BlockingIOError, InterruptedError):
                            checkpoint()
                            continue
                        checkpoint()
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        accepted = chunk[:allowance]
                        offset = 0
                        while offset < len(accepted):
                            checkpoint()
                            try:
                                written = os.write(captures[name], accepted[offset:])
                            except InterruptedError:
                                continue
                            if written <= 0:
                                raise OSError()
                            hashes[name].update(accepted[offset:offset + written])
                            counts[name] += written
                            offset += written
                            checkpoint()
                        if len(chunk) > allowance:
                            outcome = "output-limit"
                            break
            if outcome == "success":
                remaining_time = checkpoint()
                status = child.wait(timeout=remaining_time)
                checkpoint()
                if type(status) is not int or not -31 <= status <= 255:
                    status = None
                    raise _unavailable("protocol-invalid")
                outcome = "success" if status == 0 else "command-failed"
    except ProcessFailure as caught:
        if child is None:
            failure = caught
        else:
            outcome = "deadline" if caught.reason in {"deadline", "cancelled"} else "read-failed"
    except subprocess.TimeoutExpired:
        outcome = "deadline"
    except Exception:
        if child is None:
            failure = _unavailable()
        else:
            outcome = "read-failed"
    finally:
        for stream in streams:
            try:
                stream.close()
            except Exception:
                failure = _unavailable("cleanup-failed", "failed")
        for descriptor in list(captures.values()) + ([parent] if parent is not None else []):
            try:
                _close_descriptor(descriptor)
            except ProcessFailure as caught:
                failure = caught
    if failure is not None:
        raise failure
    try:
        checkpoint()
    except ProcessFailure as caught:
        outcome = "deadline" if caught.reason in {"deadline", "cancelled"} else "read-failed"
    return CommandReceipt(outcome, status, counts["stdout"], counts["stderr"],
                          hashes["stdout"].hexdigest(), hashes["stderr"].hexdigest())


def _send_worker_receipt(descriptor, frame, *, checkpoint):
    checkpoint()
    if (type(frame) is not bytes or not 0 < len(frame) <= MAX_RECEIPT_BYTES
            or not frame.endswith(b"\n") or frame.count(b"\n") != 1):
        raise _unavailable("protocol-invalid")
    try:
        os.set_blocking(descriptor, False)
        with selectors.DefaultSelector() as selector:
            selector.register(descriptor, selectors.EVENT_WRITE)
            offset = 0
            while offset < len(frame):
                remaining = checkpoint()
                ready = selector.select(timeout=min(0.1, remaining))
                checkpoint()
                if not ready:
                    continue
                try:
                    written = os.write(descriptor, frame[offset:])
                except (BlockingIOError, InterruptedError):
                    checkpoint()
                    continue
                checkpoint()
                if written <= 0:
                    raise _unavailable("protocol-invalid")
                offset += written
        checkpoint()
    except ProcessFailure:
        raise
    except Exception:
        raise _unavailable("protocol-invalid") from None


def _hold_worker(*, deadline, clock, sleep):
    # Qualification supplies the captured shared clock. This is only a
    # cooperative post-report checkpoint loop, never a synchronous-stall timer.
    if not _valid_time(deadline):
        raise _unavailable("deadline")
    previous = None
    while True:
        try:
            now = clock()
        except Exception:
            raise _unavailable("deadline") from None
        if not _valid_time(now) or (previous is not None and now < previous):
            raise _unavailable("deadline")
        previous = now
        if now >= deadline + 3.0:
            try:
                os.killpg(os.getpid(), signal.SIGKILL)
            except Exception:
                raise _unavailable("cleanup-failed", "failed") from None
            raise _unavailable("cleanup-failed", "failed")
        try:
            sleep(min(0.1, deadline + 3.0 - now))
        except Exception:
            raise _unavailable("deadline") from None


def _run_worker_body(command, request, context, directory, *, request_fd,
                     receipt_fd, clock, sleep):
    checkpoint = _bounded_clock(clock, command.deadline)
    owned_request = request_fd
    try:
        receipt = _capture_worker_command(command, directory, request_fd=request_fd,
                                          receipt_fd=receipt_fd, checkpoint=checkpoint)
        descriptor, owned_request = owned_request, None
        _close_descriptor(descriptor)
        checkpoint()
        frame = encode_receipt(receipt, request=request, context=context)
        _send_worker_receipt(receipt_fd, frame, checkpoint=checkpoint)
    finally:
        # Request-close uncertainty must precede any complete success frame.
        # The noninherited receipt writer stays open through hold: proven outer
        # group cleanup supplies its kernel closure and the parent's EOF check.
        # There is no fallible worker-side receipt close after success publication.
        try:
            if owned_request is not None:
                descriptor, owned_request = owned_request, None
                _close_descriptor(descriptor)
        finally:
            _hold_worker(deadline=command.deadline, clock=clock, sleep=sleep)


def _stat_key(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _directory_key(info):
    # Child creation changes directory size/timestamps. Its original inode,
    # ownership and mode remain the namespace authority for this command.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)


def _close_descriptor(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        # An uncertain close cannot be retried using a possibly reused number.
        raise _unavailable("cleanup-failed", "failed") from None


def _read_owned_capture(path, maximum, checkpoint, expected_directory):
    checkpoint()
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        owner = os.fstat(parent)
        if (expected_directory is None or _directory_key(owner) != expected_directory
                or owner.st_mode & 0o777 != 0o700 or owner.st_uid != os.getuid()):
            raise _unavailable("identity-drift")
        before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or before.st_mode & 0o777 != 0o600
                or before.st_uid != os.getuid() or before.st_size > maximum):
            raise _unavailable("identity-drift")
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                             dir_fd=parent)
        try:
            if _stat_key(os.fstat(descriptor)) != _stat_key(before):
                raise _unavailable("identity-drift")
            result = bytearray()
            while True:
                checkpoint()
                chunk = os.read(descriptor, min(65536, maximum - len(result) + 1))
                checkpoint()
                if not chunk:
                    break
                result.extend(chunk)
                if len(result) > maximum:
                    raise _unavailable("identity-drift")
            if (len(result) != before.st_size
                    or _stat_key(os.fstat(descriptor)) != _stat_key(before)
                    or _stat_key(os.stat(path.name, dir_fd=parent, follow_symlinks=False))
                    != _stat_key(before)):
                raise _unavailable("identity-drift")
        finally:
            _close_descriptor(descriptor)
        current = path.parent.lstat()
        if _directory_key(current) != expected_directory:
            raise _unavailable("identity-drift")
    finally:
        _close_descriptor(parent)
    checkpoint()
    return bytes(result)


def _remove_command_directory(directory, expected_directory):
    """Remove only the fixed immediate command artifacts, never follow links."""
    allowed = {"request.json", "stdout.bin", "stderr.bin"}
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        # Fixed filenames alone confer no right to remove a replacement's
        # files. Require the namespace captured when this command created it.
        if (expected_directory is None or _directory_key(before) != expected_directory
                or before.st_uid != os.getuid()):
            raise _unavailable("cleanup-failed", "failed")
        names = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) == len(allowed) or entry.name not in allowed:
                    raise _unavailable("cleanup-failed", "failed")
                names.append(entry.name)
        for name in names:
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                raise _unavailable("cleanup-failed", "failed")
            os.unlink(name, dir_fd=descriptor)
        current = directory.lstat()
        if _directory_key(current) != expected_directory:
            raise _unavailable("cleanup-failed", "failed")
        directory.rmdir()
    finally:
        _close_descriptor(descriptor)


def _receive_receipt(descriptor, checkpoint):
    os.set_blocking(descriptor, False)
    result = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(descriptor, selectors.EVENT_READ)
        while True:
            remaining = checkpoint()
            selector.select(min(0.05, remaining))
            checkpoint()
            try:
                chunk = os.read(descriptor, MAX_RECEIPT_BYTES - len(result) + 1)
            except (BlockingIOError, InterruptedError):
                continue
            checkpoint()
            if not chunk:
                raise _unavailable("protocol-invalid")
            result.extend(chunk)
            if len(result) > MAX_RECEIPT_BYTES:
                raise _unavailable("protocol-invalid")
            if b"\n" in result:
                if result.count(b"\n") != 1 or not result.endswith(b"\n"):
                    raise _unavailable("protocol-invalid")
                return bytes(result)


def _receipt_has_no_tail(descriptor, checkpoint):
    checkpoint()
    try:
        tail = os.read(descriptor, 1)
    except (BlockingIOError, InterruptedError):
        # The retained group has already been cleaned. A live writer or an
        # uncertain trailing-frame check cannot establish complete protocol.
        raise _unavailable("protocol-invalid") from None
    checkpoint()
    if tail:
        raise _unavailable("protocol-invalid")


class QualifiedProcessSession:
    @classmethod
    def prepare(cls, trusted_root: TrustedRunnerRoot, profile_id: str):
        if cls is not QualifiedProcessSession:
            raise _unavailable()
        context = require_trusted_entry_context(TrustedEntryContext(
            trusted_root, getattr(trusted_root, "expected_manifest_sha256", None), profile_id))
        clock, started, deadline = context.trusted_root.budget._consume()
        value = cls()
        value._clock = clock
        value._last_clock = started
        value._state = "preparing"
        value._prepared = False
        value._failed = False
        value._cancelled = False
        value._close_attempted = False
        value._close_completed = False
        value._close_failure = None
        value._decision_slot = {}
        value._cancellation_decision = None
        value._active_anchor = None
        value._active_transport = None
        value._bootstrap_consumed = False
        value._bootstrap_deadline = deadline
        value._directory = None
        value._signal_handlers = None
        value._profile_id = profile_id
        value._session_id = os.urandom(16).hex()
        value._command_id = 0
        value._help_executables = {}
        try:
            value._checkpoint(deadline)
            value._package = _verify_package(trusted_root, deadline=deadline, clock=clock)
            value._checkpoint(deadline)
            value._profile = _select_profile(value._package, profile_id,
                                             deadline=deadline, clock=clock)
            value._checkpoint(deadline)
            value._runtime = _qualify_runtime(value._profile, deadline=deadline, clock=clock)
            value._checkpoint(deadline)
            value._directory = Path(tempfile.mkdtemp(prefix="capability-session-"))
            value._directory_identity = value._directory.lstat()
            # Retain the created spelling before any later observation can fail.
            resolved = value._directory.resolve(strict=True)
            if _stat_key(resolved.lstat()) != _stat_key(value._directory_identity):
                raise _unavailable("identity-drift")
            value._directory = resolved
            value._checkpoint(deadline)
            projection = _build_projection(value._package, value._profile,
                                            value._directory, deadline=deadline, clock=clock)
            value._checkpoint(deadline)
            value._native = _bootstrap_native(value, projection, deadline=deadline)
            value._checkpoint(deadline + 2.0)
            value._native.check_state()
            value._checkpoint(deadline + 2.0)
            value._prepared = True
            value._state = "ready"
            return value
        except Exception as failure:
            value._poison()
            try:
                value.close()
            except ProcessFailure:
                raise _unavailable("cleanup-failed", "failed") from None
            if isinstance(failure, ProcessFailure):
                raise failure
            raise _unavailable() from None

    def clock(self) -> float:
        try:
            now = self._clock()
        except Exception:
            self._poison()
            raise _unavailable("deadline") from None
        if not _valid_time(now) or now < getattr(self, "_last_clock", 0.0):
            self._poison()
            raise _unavailable("deadline")
        self._last_clock = now
        return now

    def _poison(self):
        self._failed = True
        self._state = "poisoned"

    def _checkpoint(self, deadline):
        now = self.clock()
        if self._cancelled:
            raise _unavailable("cancelled")
        if not _valid_time(deadline) or now >= deadline:
            raise _unavailable("deadline")
        return deadline - now

    def _require_ready(self):
        if self._state != "ready" or not self._prepared:
            raise _unavailable()
        if self._cancelled:
            self._poison()
            raise _unavailable("cancelled")

    @property
    def state(self) -> str:
        return self._state

    @property
    def can_validate_final_checkout(self) -> bool:
        return self._state == "ready" and not self._cancelled

    def selected_executable(self, role: str) -> ExecutableIdentity:
        self._require_ready()
        if type(role) is not str or role not in self._profile.executables:
            raise _unavailable()
        return self._profile.executables[role]

    def bind_help_executable(self, binary: Path, *, build_root: Path,
                             expected_sha256: str,
                             deadline: float) -> ExecutableIdentity:
        self._require_ready()
        parent = None
        result = None
        try:
            self._checkpoint(deadline)
            if (deadline - self.clock() > 60.0 or type(binary) is not type(Path())
                    or type(build_root) is not type(Path()) or not binary.is_absolute()
                    or not build_root.is_absolute() or type(expected_sha256) is not str
                    or _SHA256.fullmatch(expected_sha256) is None):
                raise _unavailable("identity-drift")
            canonical_root = build_root.resolve(strict=True)
            canonical_parent = binary.parent.resolve(strict=True)
            canonical_parent.relative_to(canonical_root)
            if binary != canonical_parent / binary.name:
                raise _unavailable("identity-drift")
            self._checkpoint(deadline)
            parent = os.open(canonical_parent,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            parent_identity = _directory_key(os.fstat(parent))
            payload, info = _read_regular_at(parent, binary.name, 256 * 1024 * 1024,
                                              lambda: self._checkpoint(deadline))
            result = _identity(binary, payload, info)
            self._checkpoint(deadline)
            prior = self._help_executables.get(str(binary))
            if (not result.mode & 0o111 or result.sha256 != expected_sha256
                    or (prior is not None and result != prior)
                    or _directory_key(canonical_parent.lstat()) != parent_identity):
                raise _unavailable("identity-drift")
        except ProcessFailure:
            self._poison()
            raise
        except (OSError, ValueError, TypeError):
            self._poison()
            raise _unavailable("identity-drift") from None
        finally:
            if parent is not None:
                try:
                    _close_descriptor(parent)
                except ProcessFailure:
                    self._poison()
                    raise
        try:
            self._checkpoint(deadline)
        except ProcessFailure:
            self._poison()
            raise
        self._help_executables[str(binary)] = result
        return result

    def run(self, request: CommandRequest) -> CommandResult:
        self._require_ready()
        self._active_transport = None
        transport = None
        directory = None
        directory_identity = None
        receipt = None
        payload = None
        failure = None
        context = None
        stdout = stderr = b""
        try:
            if type(request) is not CommandRequest:
                raise _unavailable("protocol-invalid")
            self._checkpoint(request.deadline)
            selected = (self._help_executables.get(request.executable.path)
                        if request.role == "help-dump"
                        else self._profile.executables.get(request.role))
            if selected != request.executable:
                raise _unavailable("identity-drift")
            if self._command_id >= MAX_COMMAND_ID:
                raise _unavailable("protocol-invalid")
            context = ProtocolContext(
                self._session_id, self._command_id + 1, self._package.sha256,
                self._profile_id, self._native.artifact.sha256)
            encode_request(request, context=context, now=self.clock())
            _revalidate_session(self, deadline=request.deadline)
            self._checkpoint(request.deadline)
            self._command_id += 1
            self._state = "command-active"
            candidate = self._directory / ("command-" + str(self._command_id))
            candidate.mkdir(mode=0o700)
            directory = candidate
            created = directory.lstat()
            if (not stat.S_ISDIR(created.st_mode) or created.st_mode & 0o777 != 0o700
                    or created.st_uid != os.getuid()):
                raise _unavailable("identity-drift")
            directory_identity = _directory_key(created)
            self._checkpoint(request.deadline)
            transport = _spawn_worker(self, request, context, directory)
            # Store the returned anchor before observing a nonraising latch.
            self._active_anchor = transport.anchor
            self._checkpoint(request.deadline)
            payload = _receive_receipt(
                transport.receipt_fd, lambda: self._checkpoint(request.deadline))
        except ProcessFailure as caught:
            failure = caught
        except Exception:
            failure = _unavailable()
        finally:
            if transport is None:
                transport = self._active_transport
            if transport is not None and transport.anchor is not None:
                try:
                    _cleanup_anchor(transport.anchor, deadline=request.deadline,
                                    clock=self.clock, observe=self._native.observe_child)
                except ProcessFailure as caught:
                    failure = caught
                finally:
                    self._active_anchor = None
        try:
            if failure is None:
                self._checkpoint(request.deadline + 2.0)
                _receipt_has_no_tail(transport.receipt_fd,
                                     lambda: self._checkpoint(request.deadline + 2.0))
                receipt = parse_receipt(payload, request=request, context=context)
                _revalidate_session(self, deadline=request.deadline + 2.0)
                self._checkpoint(request.deadline + 2.0)
                stdout = _read_owned_capture(directory / "stdout.bin",
                    request.maximum_output_bytes,
                    lambda: self._checkpoint(request.deadline + 2.0), directory_identity)
                stderr = _read_owned_capture(directory / "stderr.bin",
                    request.maximum_output_bytes - len(stdout),
                    lambda: self._checkpoint(request.deadline + 2.0), directory_identity)
                if (len(stdout) != receipt.stdout_bytes or len(stderr) != receipt.stderr_bytes
                        or hashlib.sha256(stdout).hexdigest() != receipt.stdout_sha256
                        or hashlib.sha256(stderr).hexdigest() != receipt.stderr_sha256):
                    raise _unavailable("identity-drift")
                self._checkpoint(request.deadline + 2.0)
        except ProcessFailure as caught:
            failure = caught
        except Exception:
            failure = _unavailable("identity-drift")
        finally:
            if transport is not None:
                try:
                    _close_worker_transport(transport)
                except ProcessFailure:
                    failure = _unavailable("cleanup-failed", "failed")
            self._active_transport = None
            if directory is not None:
                try:
                    _remove_command_directory(directory, directory_identity)
                except Exception:
                    failure = _unavailable("cleanup-failed", "failed")
        if failure is None:
            try:
                self._checkpoint(request.deadline + 2.0)
            except ProcessFailure as caught:
                failure = caught
        if failure is not None:
            self._poison()
            raise failure
        if receipt.outcome == "deadline":
            self._poison()
            raise _unavailable("deadline", "complete")
        self._state = "ready"
        if receipt.outcome != "success":
            reason = {"command-failed": "command-failed", "output-limit": "output-limit",
                      "launch-failed": "process-unavailable", "read-failed": "process-unavailable"}[receipt.outcome]
            raise ProcessFailure(reason, command_status=receipt.command_status,
                                 cleanup_disposition="complete", session_disposition="ready")
        return CommandResult(stdout, stderr, 0, True)

    def _latch_cancellation(self, _signal_number, _frame):
        self._cancelled = True
        alternative = self._cancellation_decision
        if alternative is not None:
            # Exact built-in dict operation shares the decision linearization
            # point with finalize_decision under the admitted CPython runtime.
            self._decision_slot.setdefault("decision", alternative)

    def close(self) -> None:
        # Resource reclamation does not erase an earlier terminal session
        # failure. Finalization must retain that history even after close.
        if self._state == "poisoned":
            self._failed = True
        if self._close_attempted:
            if self._close_failure is not None:
                raise self._close_failure
            return
        self._close_attempted = True
        if self._active_anchor is not None:
            self._failed = True
            self._state = "poisoned"
            self._close_failure = _unavailable("cleanup-failed", "failed")
            raise self._close_failure
        if self._directory is not None:
            try:
                current = self._directory.lstat()
                expected = getattr(self, "_directory_identity", current)
                if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid()
                        or (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)):
                    raise _unavailable("cleanup-failed", "failed")
                # Projection/artifact teardown belongs to the qualification
                # implementation. Never sweep unknown files to claim closure.
                self._directory.rmdir()
                self._directory = None
            except Exception:
                self._poison()
                self._close_failure = _unavailable("cleanup-failed", "failed")
                raise self._close_failure from None
        self._close_completed = True
        self._state = "closed"

    def finalize_decision(self, *, proposed: ProcessDecision,
                          cancelled: ProcessDecision) -> ProcessDecision:
        if "decision" in self._decision_slot:
            return self._decision_slot["decision"]
        if (type(proposed) is not ProcessDecision
                or type(cancelled) is not ProcessDecision
                or cancelled.exit_code == 0 or not self._close_attempted
                or (proposed.exit_code == 0
                    and (not self._close_completed
                         or getattr(self, "_failed", False)))):
            raise _unavailable("cleanup-failed", "failed")
        self._cancellation_decision = cancelled
        if self._cancelled:
            self._decision_slot.setdefault("decision", cancelled)
        return self._decision_slot.setdefault("decision", proposed)
