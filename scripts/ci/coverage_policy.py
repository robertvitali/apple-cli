#!/usr/bin/env python3
"""Enforce production coverage policy from llvm-cov LCOV exports."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import tempfile
import time
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


MIN_COVERAGE_NUMERATOR = 90
MIN_COVERAGE_DENOMINATOR = 100
MAX_ARTIFACT_BYTES = 250_000_000
MAX_SOURCE_BYTES = 25_000_000
MAX_CHANGED_LINES = 100_000
MAX_CHANGED_FILES = 1_000
MAX_DIFF_FILES = 500
MAX_DIFF_OUTPUT_BYTES = 25_000_000
MAX_LINE_STATUS_LINES = 1_000_000
MAX_TOOL_OUTPUT_BYTES = 250_000_000
MAX_TOTAL_SHOW_OUTPUT_BYTES = 50_000_000
MAX_TOTAL_SHOW_SECONDS = 120.0
MAX_GIT_OUTPUT_BYTES = 25_000_000
MAX_GIT_SCALAR_OUTPUT_BYTES = 128
MAX_GIT_ERROR_OUTPUT_BYTES = 1_000_000
MAX_GIT_SECONDS = 10.0
MAX_DECIMAL_DIGITS = 20
MAX_LINE_COUNT_FIELD_CHARS = 64
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
IGNORED_SOURCE_TARGETS = frozenset(("TestSupport",))
GIT_CONFIG_ARGS = (
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "credential.helper=",
)
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_OPTIONAL_LOCKS": "0",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
}
XCRUN_ENV = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR": "/private/tmp",
}
DECLARATION_ONLY_COVERAGE_EXCLUSIONS = {
    "Sources/AppleKit/AppleScriptRunning.swift": {
        "blob_sha": "2da806f8fb987a9c2b043b2ad35556cee43dc437",
        "reason": "protocol-only seam with no executable coverage regions",
    },
    "Sources/MessagesKit/Models.swift": {
        "blob_sha": "f87952838dd753807ede5e1d7162da297a99e86d",
        "reason": "payload type declarations with no executable coverage regions",
    },
}
LINE_STATUSES = frozenset(("covered", "uncovered", "non_coverable"))
PUBLIC_POLICY_ERROR_MESSAGES = frozenset(
    (
        "changed-line input is invalid",
        "checkout identity is invalid",
        "coverage input is invalid",
        "coverage tool input is invalid",
        "line-status input is invalid",
    )
)
ABBREVIATED_POSITIVE_RE = re.compile(r"^(?:[1-9][0-9]*(?:\.[0-9]+)?|[0-9]*\.[0-9]*[1-9][0-9]*)[kKmMgGtT]$")
DIFF_HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


class PolicyError(Exception):
    pass


def _public_policy_error_message(error: PolicyError) -> str:
    message = str(error)
    if message in PUBLIC_POLICY_ERROR_MESSAGES:
        return message
    return "coverage policy validation failed"


@dataclass(frozen=True)
class CoverageCount:
    covered: int
    count: int

    @property
    def percent(self) -> float:
        if self.count == 0:
            return 100.0
        return self.covered * 100.0 / self.count

    def meets_floor(self) -> bool:
        return self.covered * MIN_COVERAGE_DENOMINATOR >= self.count * MIN_COVERAGE_NUMERATOR

    def regressed_from(self, base: "CoverageCount") -> bool:
        return self.covered * base.count < base.covered * self.count


@dataclass(frozen=True)
class ChangedCoverage:
    covered: int
    count: int
    status: str

    @property
    def percent(self) -> Optional[float]:
        if self.count == 0:
            return None
        return self.covered * 100.0 / self.count


@dataclass(frozen=True)
class LcovReport:
    targets: Dict[str, CoverageCount]
    line_coverage: Dict[str, Dict[int, bool]]


@dataclass(frozen=True)
class CoverageToolInputs:
    binary: Path
    profdata: Path


@dataclass(frozen=True)
class SourceFile:
    path: Path
    blob_sha: str


@dataclass(frozen=True)
class CoverageToolSnapshots:
    inputs: CoverageToolInputs
    cleanup_paths: Tuple[Path, ...]
    identities: Dict[Path, Tuple[int, int, int, str]]


@dataclass(frozen=True)
class PolicyResult:
    ok: bool
    diagnostics: str
    aggregate: CoverageCount
    changed_coverage: ChangedCoverage
    targets: Dict[str, CoverageCount]


def _reject_symlink_components(path: Path, error_message: str) -> Path:
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        try:
            if current.is_symlink():
                raise PolicyError(error_message)
        except PolicyError:
            raise
        except OSError as exc:
            raise PolicyError(error_message) from exc
    return absolute


def _secure_read_bytes(path: Path, *, max_bytes: int, error_message: str) -> bytes:
    absolute = _reject_symlink_components(path, error_message)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    try:
        fd = os.open(str(absolute), flags)
    except OSError as exc:
        raise PolicyError(error_message) from exc
    try:
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode):
            raise PolicyError(error_message)
        if file_stat.st_size > max_bytes:
            raise PolicyError(error_message)
        chunks: List[bytes] = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(fd, min(1_048_576, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise PolicyError(error_message)
        return data
    finally:
        os.close(fd)


def _secure_artifact(path: Path, *, error_message: str) -> Tuple[Path, bytes]:
    absolute = _reject_symlink_components(path, error_message)
    data = _secure_read_bytes(absolute, max_bytes=MAX_ARTIFACT_BYTES, error_message=error_message)
    try:
        canonical = absolute.resolve(strict=True)
    except OSError as exc:
        raise PolicyError(error_message) from exc
    return canonical, data


def _path_identity(path: Path, *, error_message: str) -> Tuple[int, int, int, str]:
    data = _secure_read_bytes(path, max_bytes=MAX_ARTIFACT_BYTES, error_message=error_message)
    try:
        file_stat = path.stat()
    except OSError as exc:
        raise PolicyError(error_message) from exc
    if not stat.S_ISREG(file_stat.st_mode):
        raise PolicyError(error_message)
    return (
        int(file_stat.st_dev),
        int(file_stat.st_ino),
        int(file_stat.st_size),
        hashlib.sha256(data).hexdigest(),
    )


def _write_snapshot(data: bytes, *, error_message: str) -> Path:
    temp_file = None
    path: Optional[Path] = None
    try:
        temp_file = tempfile.NamedTemporaryFile(
            prefix="apple-cli-coverage-",
            dir="/private/tmp",
            delete=False,
        )
        path = Path(temp_file.name)
        temp_file.write(data)
        temp_file.flush()
        os.fsync(temp_file.fileno())
        return path.resolve(strict=True)
    except Exception as exc:
        if path is not None:
            try:
                path.unlink()
            except OSError:
                pass
        raise PolicyError(error_message) from exc
    finally:
        if temp_file is not None:
            temp_file.close()


def _secure_read_text(path: Path, *, max_bytes: int, error_message: str) -> Tuple[str, str]:
    data = _secure_read_bytes(path, max_bytes=max_bytes, error_message=error_message)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError(error_message) from exc
    return text, hashlib.sha256(data).hexdigest()


def _parse_nonnegative_int(raw: str) -> int:
    if not raw or len(raw) > MAX_DECIMAL_DIGITS or not raw.isdigit():
        raise PolicyError("coverage input is invalid")
    try:
        return int(raw)
    except (ValueError, OverflowError) as exc:
        raise PolicyError("coverage input is invalid") from exc


def _canonical_root(path: Path, *, error_message: str) -> Path:
    try:
        root = _reject_symlink_components(path, error_message).resolve(strict=True)
        root_stat = root.stat()
    except OSError as exc:
        raise PolicyError(error_message) from exc
    if not stat.S_ISDIR(root_stat.st_mode):
        raise PolicyError(error_message)
    return root


def _run_git_bytes(
    root: Path,
    args: Sequence[str],
    *,
    error_message: str,
    max_output_bytes: int = MAX_GIT_OUTPUT_BYTES,
    timeout_seconds: float = MAX_GIT_SECONDS,
) -> bytes:
    return _run_bounded_command_bytes(
        ["/usr/bin/git", *GIT_CONFIG_ARGS, "-C", str(root), *args],
        root,
        error_message=error_message,
        allowed_return_codes={0},
        max_output_bytes=max_output_bytes,
        timeout_seconds=timeout_seconds,
        env=GIT_ENV,
    )


def _run_git(
    root: Path,
    args: Sequence[str],
    *,
    error_message: str,
    max_output_bytes: int = MAX_GIT_OUTPUT_BYTES,
    timeout_seconds: float = MAX_GIT_SECONDS,
) -> str:
    output = _run_git_bytes(
        root,
        args,
        error_message=error_message,
        max_output_bytes=max_output_bytes,
        timeout_seconds=timeout_seconds,
    )
    try:
        return output.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError(error_message) from exc


def _validate_checkout(repository_root: Path, expected_sha: str) -> Path:
    if not isinstance(expected_sha, str) or not SHA_RE.match(expected_sha):
        raise PolicyError("checkout identity is invalid")
    root = _canonical_root(repository_root, error_message="checkout identity is invalid")
    try:
        toplevel = Path(_run_git(root, ("rev-parse", "--show-toplevel"), error_message="checkout identity is invalid").strip()).resolve(strict=True)
    except OSError as exc:
        raise PolicyError("checkout identity is invalid") from exc
    if toplevel != root:
        raise PolicyError("checkout identity is invalid")
    head = _run_git(root, ("rev-parse", "HEAD"), error_message="checkout identity is invalid").strip()
    if head != expected_sha:
        raise PolicyError("checkout identity is invalid")
    dirty = _run_git(root, ("status", "--porcelain=v1", "-z", "--", "."), error_message="checkout identity is invalid")
    if dirty:
        raise PolicyError("checkout identity is invalid")
    return root


def _git_tree_source_files(root: Path, revision: str = "HEAD") -> Dict[str, SourceFile]:
    raw = _run_git(root, ("ls-tree", "-r", "-z", revision, "--", "Sources"), error_message="checkout identity is invalid")
    files: Dict[str, SourceFile] = {}
    for entry in raw.split("\0"):
        if not entry:
            continue
        try:
            metadata, rel = entry.split("\t", 1)
            _mode, kind, blob_sha = metadata.split(" ", 2)
        except ValueError as exc:
            raise PolicyError("checkout identity is invalid") from exc
        if kind != "blob" or not rel.endswith(".swift") or not SHA_RE.match(blob_sha):
            continue
        parts = Path(rel).parts
        if len(parts) < 3 or parts[0] != "Sources" or parts[1] in IGNORED_SOURCE_TARGETS:
            continue
        path = root / rel
        try:
            file_stat = path.stat()
        except OSError as exc:
            raise PolicyError("checkout identity is invalid") from exc
        if not stat.S_ISREG(file_stat.st_mode) or _has_symlink_component_absolute(path, root):
            raise PolicyError("checkout identity is invalid")
        files[rel] = SourceFile(path=path, blob_sha=blob_sha)
    return files


def _target_inventory_from_files(files: Dict[str, SourceFile]) -> Set[str]:
    return {Path(rel).parts[1] for rel in files}


def _is_reviewed_declaration_only(rel: str, source: SourceFile) -> bool:
    policy = DECLARATION_ONLY_COVERAGE_EXCLUSIONS.get(rel)
    return policy is not None and source.blob_sha == policy["blob_sha"]


def _reportable_source_files(files: Dict[str, SourceFile]) -> Dict[str, SourceFile]:
    return {
        rel: source
        for rel, source in files.items()
        if not _is_reviewed_declaration_only(rel, source)
    }


def _has_symlink_component_absolute(path: Path, root: Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return True
    current = root
    for part in rel.parts:
        current = current / part
        try:
            if current.is_symlink():
                return True
        except OSError:
            return True
    return False


def _locate_source(raw: str, repository_root: Path, files: Dict[str, SourceFile]) -> Optional[Tuple[str, str]]:
    if not raw or "\x00" in raw:
        raise PolicyError("coverage input is invalid")
    raw_path = Path(raw)
    if not raw_path.is_absolute() or ".." in raw_path.parts:
        raise PolicyError("coverage input is invalid")
    root = _canonical_root(repository_root, error_message="coverage input is invalid")
    try:
        raw_path.relative_to(root)
    except ValueError:
        return None
    try:
        canonical = raw_path.resolve(strict=True)
    except OSError as exc:
        raise PolicyError("coverage input is invalid") from exc
    if canonical != raw_path:
        raise PolicyError("coverage input is invalid")
    try:
        file_stat = canonical.stat()
    except OSError as exc:
        raise PolicyError("coverage input is invalid") from exc
    if not stat.S_ISREG(file_stat.st_mode) or _has_symlink_component_absolute(canonical, root):
        raise PolicyError("coverage input is invalid")
    rel = "/".join(canonical.relative_to(root).parts)
    parts = Path(rel).parts
    if len(parts) < 3 or parts[0] != "Sources":
        return None
    if parts[1] in IGNORED_SOURCE_TARGETS:
        return None
    if rel not in files:
        raise PolicyError("coverage input is invalid")
    if _is_reviewed_declaration_only(rel, files[rel]):
        return None
    return parts[1], rel


class _Record:
    def __init__(self) -> None:
        self.sf: Optional[str] = None
        self.target: Optional[str] = None
        self.rel: Optional[str] = None
        self.da: Dict[int, int] = {}
        self.lf: Optional[int] = None
        self.lh: Optional[int] = None

    @property
    def has_summary(self) -> bool:
        return self.lf is not None or self.lh is not None


def _parse_lcov_text(text: str, repository_root: Path) -> LcovReport:
    root = _canonical_root(repository_root, error_message="coverage input is invalid")
    source_files = _git_tree_source_files(root)
    targets: Dict[str, CoverageCount] = {}
    line_coverage: Dict[str, Dict[int, bool]] = {}
    seen_sources: Set[str] = set()
    record: Optional[_Record] = None

    def ensure_record() -> _Record:
        nonlocal record
        if record is None:
            record = _Record()
        return record

    def finish(current: _Record) -> None:
        if current.sf is None:
            raise PolicyError("coverage input is invalid")
        if current.rel is None or current.target is None:
            return
        if current.lf is None or current.lh is None:
            raise PolicyError("coverage input is invalid")
        covered_da = sum(1 for hits in current.da.values() if hits > 0)
        if current.lf < len(current.da) or current.lh < covered_da or current.lh > current.lf:
            raise PolicyError("coverage input is invalid")
        existing = targets.get(current.target, CoverageCount(0, 0))
        targets[current.target] = CoverageCount(
            covered=existing.covered + current.lh,
            count=existing.count + current.lf,
        )
        line_coverage[current.rel] = {line: hits > 0 for line, hits in current.da.items()}

    for raw_line in text.splitlines():
        if raw_line == "":
            continue
        if raw_line == "end_of_record":
            current = ensure_record()
            finish(current)
            record = None
            continue
        if ":" not in raw_line:
            raise PolicyError("coverage input is invalid")
        key, value = raw_line.split(":", 1)
        if key == "TN":
            if record is not None and (record.sf is not None or record.da or record.has_summary):
                raise PolicyError("coverage input is invalid")
            ensure_record()
            continue
        current = ensure_record()
        if key == "SF":
            if current.sf is not None or current.da or current.has_summary:
                raise PolicyError("coverage input is invalid")
            located = _locate_source(value, root, source_files)
            if located is not None:
                canonical = str(Path(value).resolve(strict=True))
                if canonical in seen_sources:
                    raise PolicyError("coverage input is invalid")
                seen_sources.add(canonical)
                current.sf = canonical
                current.target, current.rel = located
            else:
                current.sf = value
            continue
        if current.sf is None:
            raise PolicyError("coverage input is invalid")
        if key == "DA":
            if current.has_summary:
                raise PolicyError("coverage input is invalid")
            fields = value.split(",")
            if len(fields) not in (2, 3):
                raise PolicyError("coverage input is invalid")
            line = _parse_nonnegative_int(fields[0])
            hits = _parse_nonnegative_int(fields[1])
            if line <= 0 or line in current.da:
                raise PolicyError("coverage input is invalid")
            current.da[line] = hits
            continue
        if key == "LF":
            if current.lf is not None:
                raise PolicyError("coverage input is invalid")
            current.lf = _parse_nonnegative_int(value)
            continue
        if key == "LH":
            if current.lh is not None:
                raise PolicyError("coverage input is invalid")
            current.lh = _parse_nonnegative_int(value)
            continue
        if key in {"FN", "FNDA", "FNF", "FNH", "BRDA", "BRF", "BRH"}:
            continue
        raise PolicyError("coverage input is invalid")

    if record is not None:
        raise PolicyError("coverage input is invalid")
    return LcovReport(targets=targets, line_coverage=line_coverage)


def load_lcov(path: Path, repository_root: Path) -> LcovReport:
    text, _sha = _secure_read_text(path, max_bytes=MAX_ARTIFACT_BYTES, error_message="coverage input is invalid")
    return _parse_lcov_text(text, repository_root)


def parse_lcov_text_for_test(text: str, repository_root: Path) -> LcovReport:
    return _parse_lcov_text(text, repository_root)


def _validate_rel_source_path(raw: object, repository_root: Path, source_files: Dict[str, SourceFile], error_message: str) -> str:
    if not isinstance(raw, str) or raw == "":
        raise PolicyError(error_message)
    rel_path = Path(raw)
    if rel_path.is_absolute() or ".." in rel_path.parts:
        raise PolicyError(error_message)
    parts = rel_path.parts
    if len(parts) < 3 or parts[0] != "Sources" or parts[1] in IGNORED_SOURCE_TARGETS:
        raise PolicyError(error_message)
    rel = "/".join(parts)
    if rel not in source_files:
        raise PolicyError(error_message)
    absolute = repository_root / rel
    if _has_symlink_component_absolute(absolute, repository_root):
        raise PolicyError(error_message)
    return rel


def validate_coverage_tool_inputs(binary_path: Path, profdata_path: Path) -> CoverageToolInputs:
    binary_path, binary = _secure_artifact(binary_path, error_message="coverage tool input is invalid")
    profdata_path, profdata = _secure_artifact(profdata_path, error_message="coverage tool input is invalid")
    return CoverageToolInputs(
        binary=binary_path,
        profdata=profdata_path,
    )


def _snapshot_coverage_tool_inputs(binary_path: Path, profdata_path: Path) -> CoverageToolSnapshots:
    _binary_original, binary = _secure_artifact(binary_path, error_message="coverage tool input is invalid")
    _profdata_original, profdata = _secure_artifact(profdata_path, error_message="coverage tool input is invalid")
    cleanup_paths: List[Path] = []
    try:
        binary_snapshot = _write_snapshot(binary, error_message="coverage tool input is invalid")
        cleanup_paths.append(binary_snapshot)
        profdata_snapshot = _write_snapshot(profdata, error_message="coverage tool input is invalid")
        cleanup_paths.append(profdata_snapshot)
        return CoverageToolSnapshots(
            inputs=CoverageToolInputs(
                binary=binary_snapshot,
                profdata=profdata_snapshot,
            ),
            cleanup_paths=tuple(cleanup_paths),
            identities={
                binary_snapshot: _path_identity(binary_snapshot, error_message="coverage tool input is invalid"),
                profdata_snapshot: _path_identity(profdata_snapshot, error_message="coverage tool input is invalid"),
            },
        )
    except Exception:
        for path in cleanup_paths:
            try:
                path.unlink()
            except OSError:
                pass
        raise


def _verify_snapshot_identities(snapshots: CoverageToolSnapshots, *, error_message: str) -> None:
    for path, expected in snapshots.identities.items():
        if _path_identity(path, error_message=error_message) != expected:
            raise PolicyError(error_message)


def _classify_llvm_cov_count(raw: str) -> str:
    if len(raw) > MAX_LINE_COUNT_FIELD_CHARS:
        raise PolicyError("line-status input is invalid")
    token = raw.strip()
    if token == "":
        return "non_coverable"
    if len(token) > MAX_DECIMAL_DIGITS + 2:
        raise PolicyError("line-status input is invalid")
    if token.isascii() and token.isdigit():
        if len(token) > MAX_DECIMAL_DIGITS:
            raise PolicyError("line-status input is invalid")
        return "uncovered" if all(character == "0" for character in token) else "covered"
    digit_count = sum(character.isascii() and character.isdigit() for character in token)
    if digit_count > MAX_DECIMAL_DIGITS:
        raise PolicyError("line-status input is invalid")
    if ABBREVIATED_POSITIVE_RE.fullmatch(token):
        return "covered"
    raise PolicyError("line-status input is invalid")


def parse_llvm_cov_show(text: str) -> Dict[int, str]:
    statuses: Dict[int, str] = {}
    parsed_any = False
    for raw_line in text.splitlines():
        if raw_line == "":
            continue
        if re.match(r"^\s*\^", raw_line):
            continue
        match = re.match(r"^\s*(\d+)\|([^|]*)\|", raw_line)
        if not match:
            raise PolicyError("line-status input is invalid")
        parsed_any = True
        line = _parse_nonnegative_int(match.group(1))
        if line <= 0 or line in statuses:
            raise PolicyError("line-status input is invalid")
        status_value = _classify_llvm_cov_count(match.group(2))
        statuses[line] = status_value
        if len(statuses) > MAX_LINE_STATUS_LINES:
            raise PolicyError("line-status input is invalid")
    if not parsed_any:
        raise PolicyError("line-status input is invalid")
    return statuses


def _default_llvm_cov_export_runner(command: Sequence[str], cwd: Path) -> str:
    return _run_bounded_xcrun(command, cwd, error_message="coverage input is invalid")


def _lcov_from_llvm_cov(
    *,
    inputs: CoverageToolInputs,
    cwd: Path,
    runner=None,
) -> str:
    runner = runner or _default_llvm_cov_export_runner
    command = [
        "/usr/bin/xcrun",
        "llvm-cov",
        "export",
        "-format=lcov",
        "-instr-profile=" + str(inputs.profdata),
        str(inputs.binary),
    ]
    try:
        output = runner(command, cwd)
    except PolicyError:
        raise
    except Exception as exc:
        raise PolicyError("coverage input is invalid") from exc
    if not isinstance(output, str) or len(output.encode("utf-8")) > MAX_TOOL_OUTPUT_BYTES:
        raise PolicyError("coverage input is invalid")
    return output


def _default_llvm_cov_show_runner(command: Sequence[str], cwd: Path) -> str:
    return _run_bounded_xcrun(command, cwd, error_message="line-status input is invalid")


def _terminate_process_group(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.wait(timeout=10)
    except Exception:
        pass


def _run_bounded_command_bytes(
    command: Sequence[str],
    cwd: Path,
    *,
    error_message: str,
    allowed_return_codes: Set[int],
    max_output_bytes: int,
    timeout_seconds: float,
    env: Optional[Dict[str, str]] = None,
) -> bytes:
    if not command or max_output_bytes < 0 or timeout_seconds <= 0:
        raise PolicyError(error_message)
    process: Optional[subprocess.Popen] = None
    selector = selectors.DefaultSelector()
    stdout_chunks: List[bytes] = []
    total_size = 0
    try:
        process = subprocess.Popen(
            list(command),
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        assert process.stdout is not None
        assert process.stderr is not None
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(process.stderr.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + timeout_seconds
        while selector.get_map():
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                _terminate_process_group(process)
                raise PolicyError(error_message)
            events = selector.select(timeout=min(0.1, remaining_time))
            if not events and process.poll() is not None:
                events = selector.select(timeout=0)
            for key, _mask in events:
                stream_name = key.data
                stream = key.fileobj
                limit = min(65_536, max_output_bytes - total_size + 1)
                try:
                    chunk = os.read(stream.fileno(), limit)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                total_size += len(chunk)
                if total_size > max_output_bytes:
                    _terminate_process_group(process)
                    raise PolicyError(error_message)
                if stream_name == "stdout":
                    stdout_chunks.append(chunk)
        return_code = process.wait(timeout=10)
        if return_code not in allowed_return_codes:
            raise PolicyError(error_message)
        return b"".join(stdout_chunks)
    except PolicyError:
        raise
    except Exception as exc:
        raise PolicyError(error_message) from exc
    finally:
        for key in list(selector.get_map().values()):
            try:
                selector.unregister(key.fileobj)
            except OSError:
                pass
            try:
                key.fileobj.close()
            except OSError:
                pass
        selector.close()
        if process is not None and process.poll() is None:
            _terminate_process_group(process)


def _run_bounded_command(
    command: Sequence[str],
    cwd: Path,
    *,
    error_message: str,
    allowed_return_codes: Set[int],
    max_output_bytes: int,
    timeout_seconds: float,
    env: Optional[Dict[str, str]] = None,
) -> str:
    output = _run_bounded_command_bytes(
        command,
        cwd,
        error_message=error_message,
        allowed_return_codes=allowed_return_codes,
        max_output_bytes=max_output_bytes,
        timeout_seconds=timeout_seconds,
        env=env,
    )
    try:
        return output.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError(error_message) from exc


def _run_bounded_xcrun(
    command: Sequence[str],
    cwd: Path,
    *,
    error_message: str,
    timeout_seconds: float = 60.0,
    max_output_bytes: Optional[int] = None,
) -> str:
    if not command or command[0] != "/usr/bin/xcrun":
        raise PolicyError(error_message)
    return _run_bounded_command(
        command,
        cwd,
        error_message=error_message,
        allowed_return_codes={0},
        max_output_bytes=MAX_TOOL_OUTPUT_BYTES if max_output_bytes is None else max_output_bytes,
        timeout_seconds=timeout_seconds,
        env=XCRUN_ENV,
    )


def _run_git_diff(base_path: Path, head_path: Path) -> str:
    command = [
        "/usr/bin/git",
        *GIT_CONFIG_ARGS,
        "diff",
        "--no-index",
        "--no-ext-diff",
        "--no-renames",
        "--text",
        "--unified=0",
        "--",
        str(base_path),
        str(head_path),
    ]
    return _run_bounded_command(
        command,
        head_path.parent,
        error_message="changed-line input is invalid",
        allowed_return_codes={0, 1},
        max_output_bytes=MAX_DIFF_OUTPUT_BYTES,
        timeout_seconds=10.0,
        env=GIT_ENV,
    )


def _changed_lines_from_unified_diff(diff_text: str) -> List[int]:
    changed: List[int] = []
    for raw_line in diff_text.splitlines():
        match = DIFF_HUNK_RE.match(raw_line)
        if match is None:
            continue
        start = _parse_nonnegative_int(match.group(1))
        count = _parse_nonnegative_int(match.group(2) or "1")
        if count == 0:
            continue
        for line_number in range(start, start + count):
            changed.append(line_number)
            if len(changed) > MAX_CHANGED_LINES:
                raise PolicyError("changed-line input is invalid")
    return changed


def _line_status_from_llvm_cov(
    changed: Iterable[Tuple[str, int]],
    *,
    head_root: Path,
    binary_path: Path,
    profdata_path: Path,
    runner=None,
) -> Dict[str, Dict[int, str]]:
    statuses: Dict[str, Dict[int, str]] = {}
    changed_files = sorted({item[0] for item in changed})
    if len(changed_files) > MAX_CHANGED_FILES:
        raise PolicyError("changed-line input is invalid")
    started = time.monotonic()
    total_output_bytes = 0
    for rel in changed_files:
        remaining_seconds = MAX_TOTAL_SHOW_SECONDS - (time.monotonic() - started)
        if remaining_seconds <= 0:
            raise PolicyError("line-status input is invalid")
        command = [
            "/usr/bin/xcrun",
            "llvm-cov",
            "show",
            "--show-line-counts-or-regions",
            "-instr-profile=" + str(profdata_path),
            str(binary_path),
            rel,
        ]
        try:
            if runner is None:
                output = _run_bounded_xcrun(
                    command,
                    head_root,
                    error_message="line-status input is invalid",
                    timeout_seconds=min(60.0, remaining_seconds),
                    max_output_bytes=min(MAX_TOOL_OUTPUT_BYTES, MAX_TOTAL_SHOW_OUTPUT_BYTES - total_output_bytes),
                )
            else:
                output = runner(command, head_root)
        except PolicyError:
            raise
        except Exception as exc:
            raise PolicyError("line-status input is invalid") from exc
        if time.monotonic() - started > MAX_TOTAL_SHOW_SECONDS:
            raise PolicyError("line-status input is invalid")
        if not isinstance(output, str):
            raise PolicyError("line-status input is invalid")
        total_output_bytes += len(output.encode("utf-8"))
        if total_output_bytes > MAX_TOTAL_SHOW_OUTPUT_BYTES:
            raise PolicyError("line-status input is invalid")
        statuses[rel] = parse_llvm_cov_show(output)
    return statuses


def _read_source_lines(path: Path) -> List[str]:
    data = _secure_read_bytes(path, max_bytes=MAX_SOURCE_BYTES, error_message="checkout identity is invalid")
    try:
        return data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise PolicyError("checkout identity is invalid") from exc


def _read_blob_bytes(root: Path, source: SourceFile) -> bytes:
    if not SHA_RE.match(source.blob_sha):
        raise PolicyError("checkout identity is invalid")
    raw_size = _run_git(
        root,
        ("cat-file", "-s", source.blob_sha),
        error_message="checkout identity is invalid",
        max_output_bytes=MAX_GIT_SCALAR_OUTPUT_BYTES,
    ).strip()
    if not raw_size.isdigit():
        raise PolicyError("checkout identity is invalid")
    blob_size = int(raw_size)
    if blob_size > MAX_SOURCE_BYTES:
        raise PolicyError("checkout identity is invalid")
    data = _run_git_bytes(
        root,
        ("cat-file", "blob", source.blob_sha),
        error_message="checkout identity is invalid",
        max_output_bytes=blob_size + MAX_GIT_ERROR_OUTPUT_BYTES,
    )
    if len(data) != blob_size:
        raise PolicyError("checkout identity is invalid")
    return data


def _read_blob_lines(root: Path, source: SourceFile) -> List[str]:
    data = _read_blob_bytes(root, source)
    try:
        return data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise PolicyError("checkout identity is invalid") from exc


def _write_temp_blob(data: bytes) -> Path:
    return _write_snapshot(data, error_message="changed-line input is invalid")


def _derive_changed_head_lines(
    base_root: Path,
    head_root: Path,
    base_files: Dict[str, SourceFile],
    head_files: Dict[str, SourceFile],
) -> Set[Tuple[str, int]]:
    changed: Set[Tuple[str, int]] = set()
    candidate_files = sorted(
        rel
        for rel in set(base_files) | set(head_files)
        if head_files.get(rel) is not None
        and (base_files.get(rel) is None or base_files[rel].blob_sha != head_files[rel].blob_sha)
    )
    if len(candidate_files) > MAX_DIFF_FILES:
        raise PolicyError("changed-line input is invalid")

    def add_changed(rel: str, line_number: int) -> None:
        changed.add((rel, line_number))
        if len(changed) > MAX_CHANGED_LINES:
            raise PolicyError("changed-line input is invalid")

    for rel in candidate_files:
        base_source = base_files.get(rel)
        head_source = head_files[rel]
        if base_source is None:
            head_lines = _read_blob_lines(head_root, head_source)
            for line_number in range(1, len(head_lines) + 1):
                add_changed(rel, line_number)
            continue
        base_blob = _read_blob_bytes(base_root, base_source)
        head_blob = _read_blob_bytes(head_root, head_source)
        temp_paths: List[Path] = []
        try:
            base_path = _write_temp_blob(base_blob)
            temp_paths.append(base_path)
            head_path = _write_temp_blob(head_blob)
            temp_paths.append(head_path)
            diff_text = _run_git_diff(base_path, head_path)
        finally:
            for path in temp_paths:
                try:
                    path.unlink()
                except OSError:
                    pass
        if not diff_text:
            continue
        changed_lines = _changed_lines_from_unified_diff(diff_text)
        if not changed_lines and base_source.blob_sha != head_source.blob_sha:
            raise PolicyError("changed-line input is invalid")
        for line_number in changed_lines:
            add_changed(rel, line_number)
    return changed


def _aggregate(targets: Dict[str, CoverageCount]) -> CoverageCount:
    return CoverageCount(
        sum(item.covered for item in targets.values()),
        sum(item.count for item in targets.values()),
    )


def _changed_coverage(
    changed: Iterable[Tuple[str, int]],
    line_status: Dict[str, Dict[int, str]],
) -> ChangedCoverage:
    coverable = 0
    covered = 0
    for rel, line in changed:
        file_status = line_status.get(rel)
        if file_status is None or line not in file_status:
            raise PolicyError("line-status input is invalid")
        status_value = file_status[line]
        if status_value == "non_coverable":
            continue
        coverable += 1
        if status_value == "covered":
            covered += 1
    if coverable == 0:
        return ChangedCoverage(covered=0, count=0, status="N/A")
    return ChangedCoverage(
        covered=covered,
        count=coverable,
        status="PASS" if CoverageCount(covered, coverable).meets_floor() else "FAIL",
    )


def _append_diagnostic(diagnostics: List[str], message: str) -> None:
    if message not in diagnostics:
        diagnostics.append(message)


def _validate_report_inventory(
    report: LcovReport,
    inventory: Set[str],
    *,
    missing_message: str,
    zero_message: str,
    diagnostics: List[str],
) -> None:
    for target in sorted(inventory):
        count = report.targets.get(target)
        if count is None:
            _append_diagnostic(diagnostics, missing_message)
        elif count.count == 0:
            _append_diagnostic(diagnostics, zero_message)


def _validate_file_completeness(
    report: LcovReport,
    files: Dict[str, SourceFile],
    *,
    missing_message: str,
    diagnostics: List[str],
) -> None:
    for rel, source in sorted(files.items()):
        if _is_reviewed_declaration_only(rel, source):
            continue
        if rel not in report.line_coverage:
            _append_diagnostic(diagnostics, missing_message)
            return


def evaluate_policy(
    *,
    base_coverage_binary_path: Path,
    base_profdata_path: Path,
    head_coverage_binary_path: Path,
    head_profdata_path: Path,
    base_repository_root: Path,
    head_repository_root: Path,
    expected_base_sha: str,
    expected_head_sha: str,
    llvm_cov_export_runner=None,
    llvm_cov_show_runner=None,
) -> PolicyResult:
    cleanup_paths: List[Path] = []
    try:
        base_root = _validate_checkout(base_repository_root, expected_base_sha)
        head_root = _validate_checkout(head_repository_root, expected_head_sha)
        base_snapshot = _snapshot_coverage_tool_inputs(base_coverage_binary_path, base_profdata_path)
        cleanup_paths.extend(base_snapshot.cleanup_paths)
        head_snapshot = _snapshot_coverage_tool_inputs(head_coverage_binary_path, head_profdata_path)
        cleanup_paths.extend(head_snapshot.cleanup_paths)
        base_files = _git_tree_source_files(base_root, expected_base_sha)
        head_files = _git_tree_source_files(head_root, expected_head_sha)
        base_reportable_files = _reportable_source_files(base_files)
        head_reportable_files = _reportable_source_files(head_files)
        base_inventory = _target_inventory_from_files(base_reportable_files)
        head_inventory = _target_inventory_from_files(head_reportable_files)
        base_lcov_text = _lcov_from_llvm_cov(
            inputs=base_snapshot.inputs,
            cwd=base_root,
            runner=llvm_cov_export_runner,
        )
        _verify_snapshot_identities(base_snapshot, error_message="coverage tool input is invalid")
        head_lcov_text = _lcov_from_llvm_cov(
            inputs=head_snapshot.inputs,
            cwd=head_root,
            runner=llvm_cov_export_runner,
        )
        _verify_snapshot_identities(head_snapshot, error_message="coverage tool input is invalid")
        base_report = _parse_lcov_text(base_lcov_text, base_root)
        head_report = _parse_lcov_text(head_lcov_text, head_root)
        if (base_inventory and not base_report.targets) or (head_inventory and not head_report.targets):
            raise PolicyError("coverage input is invalid")
        changed = _derive_changed_head_lines(base_root, head_root, base_files, head_files)
        line_status = _line_status_from_llvm_cov(
            changed,
            head_root=head_root,
            binary_path=head_snapshot.inputs.binary,
            profdata_path=head_snapshot.inputs.profdata,
            runner=llvm_cov_show_runner,
        )
        _verify_snapshot_identities(head_snapshot, error_message="coverage tool input is invalid")
        _validate_checkout(base_root, expected_base_sha)
        _validate_checkout(head_root, expected_head_sha)
    except PolicyError as exc:
        return PolicyResult(
            ok=False,
            diagnostics=_public_policy_error_message(exc),
            aggregate=CoverageCount(0, 0),
            changed_coverage=ChangedCoverage(0, 0, "FAIL"),
            targets={},
        )
    finally:
        for path in cleanup_paths:
            try:
                path.unlink()
            except OSError:
                pass

    diagnostics: List[str] = []
    _validate_report_inventory(
        base_report,
        base_inventory,
        missing_message="missing required base target",
        zero_message="required base target has zero coverable lines",
        diagnostics=diagnostics,
    )
    _validate_report_inventory(
        head_report,
        head_inventory,
        missing_message="missing required head target",
        zero_message="required head target has zero coverable lines",
        diagnostics=diagnostics,
    )
    _validate_file_completeness(
        base_report,
        base_files,
        missing_message="missing coverage record for base production file",
        diagnostics=diagnostics,
    )
    _validate_file_completeness(
        head_report,
        head_files,
        missing_message="missing coverage record for head production file",
        diagnostics=diagnostics,
    )
    if base_inventory - head_inventory:
        _append_diagnostic(diagnostics, "missing required head target")
    if any(target not in base_inventory for target in base_report.targets):
        _append_diagnostic(diagnostics, "unexpected base target")
    if any(target not in head_inventory for target in head_report.targets):
        _append_diagnostic(diagnostics, "unexpected head target")

    aggregate = _aggregate(head_report.targets)
    if not aggregate.meets_floor():
        _append_diagnostic(diagnostics, "aggregate coverage is below 90%")

    try:
        changed_cov = _changed_coverage(changed, line_status)
    except PolicyError as exc:
        return PolicyResult(
            ok=False,
            diagnostics=_public_policy_error_message(exc),
            aggregate=aggregate,
            changed_coverage=ChangedCoverage(0, 0, "FAIL"),
            targets=head_report.targets,
        )
    if changed_cov.status == "FAIL":
        _append_diagnostic(diagnostics, "changed-line coverage is below 90%")

    for target, head in sorted(head_report.targets.items()):
        if target not in base_report.targets:
            if not head.meets_floor():
                _append_diagnostic(diagnostics, "target coverage is below 90%")
            continue
        base = base_report.targets[target]
        if not head.meets_floor():
            _append_diagnostic(diagnostics, "target coverage is below 90%")
        if head.regressed_from(base):
            _append_diagnostic(diagnostics, "target coverage regressed")

    return PolicyResult(
        ok=not diagnostics,
        diagnostics="\n".join(diagnostics),
        aggregate=aggregate,
        changed_coverage=changed_cov,
        targets=head_report.targets,
    )


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Enforce apple-cli coverage policy.")
    parser.add_argument("--base-coverage-binary", required=True, type=Path)
    parser.add_argument("--base-profdata", required=True, type=Path)
    parser.add_argument("--head-coverage-binary", required=True, type=Path)
    parser.add_argument("--head-profdata", required=True, type=Path)
    parser.add_argument("--base-repository-root", required=True, type=Path)
    parser.add_argument("--head-repository-root", required=True, type=Path)
    parser.add_argument("--expected-base-sha", required=True)
    parser.add_argument("--expected-head-sha", required=True)
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    result = evaluate_policy(
        base_coverage_binary_path=args.base_coverage_binary,
        base_profdata_path=args.base_profdata,
        head_coverage_binary_path=args.head_coverage_binary,
        head_profdata_path=args.head_profdata,
        base_repository_root=args.base_repository_root,
        head_repository_root=args.head_repository_root,
        expected_base_sha=args.expected_base_sha,
        expected_head_sha=args.expected_head_sha,
    )
    if result.ok:
        print(
            "coverage policy passed "
            f"(aggregate {result.aggregate.covered}/{result.aggregate.count}; "
            f"changed {result.changed_coverage.status})"
        )
        return 0
    print("coverage policy failed")
    if result.diagnostics:
        print(result.diagnostics)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
