#!/usr/bin/env python3
"""Repository-owned quality gate for local and hosted CI runs."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from enum import Enum
import io
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable, Iterable, List, Optional, Sequence, Tuple
import xml.etree.ElementTree as ET


POLICY_ROOT = Path(__file__).resolve().parents[2]
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_XUNIT_BYTES = 8 * 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 8 * 1024 * 1024
GIT_TIMEOUT_SECONDS = 30
TIMEOUT_STATUS = 124
SPAWN_FAILURE_STATUS = 125
OUTPUT_LIMIT_STATUS = 126
POLICY_FAILURE_STATUS = 2
ASSERTION_FAILURE_STATUS = 1
OUTPUT_LIMIT_DIAGNOSTIC = b"quality: child output exceeded limit\n"
CANCELLATION_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
GIT_CONFIG_OVERRIDES = (
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "credential.helper=",
    "-c",
    "credential.interactive=false",
    "-c",
    "core.askPass=",
)
GIT_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LC_ALL": "C",
    "LANG": "C",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
}


class Mode(Enum):
    LOCAL = "local"
    HOSTED = "hosted"


class HostedContext(Enum):
    PULL_REQUEST = "pull-request"
    TRUSTED_REF = "trusted-ref"


class PolicyError(Exception):
    """Caller supplied invalid policy inputs."""


class AssertionFailure(Exception):
    """A quality assertion failed."""


class CancellationRequested(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


@dataclass(frozen=True)
class CommandResult:
    status: int
    output: bytes = b""


@dataclass(frozen=True)
class QualityResult:
    status: int
    stdout: Tuple[str, ...] = ()
    stderr: Tuple[str, ...] = ()


@dataclass(frozen=True)
class QualityRequest:
    mode: Mode
    hosted_context: Optional[HostedContext]
    policy_root: Path
    candidate_root: Path
    candidate_sha: Optional[str]
    base_sha: Optional[str]
    stages: Tuple[str, ...]
    list_stages: bool = False


CommandBuilder = Callable[[Path, Path, Path], Tuple[str, ...]]


@dataclass(frozen=True)
class Stage:
    name: str
    modes: frozenset[Mode]
    command: CommandBuilder
    timeout: float
    grace: float
    requires_xunit: bool = False
    isolated_home: bool = False


def bats_inventory_command(
    policy_root: Path,
    candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        sys.executable,
        str(policy_root / "scripts" / "ci" / "bats_inventory.py"),
        "--root",
        str(candidate_root),
        "--manifest",
        str(candidate_root / "bats" / "tier-inventory.json"),
        "--policy-root",
        str(policy_root),
        "--policy-manifest",
        str(policy_root / "bats" / "tier-inventory.json"),
    )


def swiftly_build_command(
    _policy_root: Path,
    _candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        str(Path.home() / ".swiftly" / "bin" / "swift"),
        "build",
        "--scratch-path",
        ".build-swiftly",
        "--disable-automatic-resolution",
    )


def swiftly_test_command(
    _policy_root: Path,
    _candidate_root: Path,
    xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        str(Path.home() / ".swiftly" / "bin" / "swift"),
        "test",
        "--scratch-path",
        ".build-swiftly",
        "--disable-automatic-resolution",
        f"--xunit-output={xunit_dir / 'swiftly-test.xml'}",
    )


def hosted_build_command(
    _policy_root: Path,
    _candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        "swift",
        "build",
        "--disable-automatic-resolution",
    )


def hosted_test_command(
    _policy_root: Path,
    _candidate_root: Path,
    xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        "swift",
        "test",
        "--disable-automatic-resolution",
        f"--xunit-output={xunit_dir / 'hosted-test.xml'}",
    )


def clt_build_command(
    _policy_root: Path,
    _candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    return (
        "/usr/bin/swift",
        "build",
        "--disable-automatic-resolution",
    )


def bats_local_command(
    _policy_root: Path,
    _candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    system_first_path = "/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", "")
    return (
        "/usr/bin/env",
        f"PATH={system_first_path}",
        "bats",
        "-r",
        "bats/",
    )


def bats_hosted_command(
    _policy_root: Path,
    _candidate_root: Path,
    _xunit_dir: Path,
) -> Tuple[str, ...]:
    system_first_path = "/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", "")
    return (
        "/usr/bin/env",
        f"PATH={system_first_path}",
        "bats",
        "-r",
        "bats/hosted/",
    )


STAGES = (
    Stage(
        "bats-inventory",
        frozenset((Mode.LOCAL, Mode.HOSTED)),
        bats_inventory_command,
        60,
        5,
    ),
    Stage("swiftly-build", frozenset((Mode.LOCAL,)), swiftly_build_command, 900, 15),
    Stage(
        "swiftly-test",
        frozenset((Mode.LOCAL,)),
        swiftly_test_command,
        1200,
        15,
        requires_xunit=True,
    ),
    Stage("clt-build", frozenset((Mode.LOCAL,)), clt_build_command, 900, 15),
    Stage("bats-local", frozenset((Mode.LOCAL,)), bats_local_command, 1800, 15),
    Stage(
        "hosted-build",
        frozenset((Mode.HOSTED,)),
        hosted_build_command,
        900,
        15,
        isolated_home=True,
    ),
    Stage(
        "hosted-test",
        frozenset((Mode.HOSTED,)),
        hosted_test_command,
        1200,
        15,
        requires_xunit=True,
        isolated_home=True,
    ),
    Stage(
        "bats-hosted",
        frozenset((Mode.HOSTED,)),
        bats_hosted_command,
        1800,
        15,
        isolated_home=True,
    ),
)


def validate_stage_registry(stages: Sequence[Stage]) -> None:
    seen = set()
    for stage in stages:
        if stage.name in seen:
            raise PolicyError(f"duplicate stage name: {stage.name}")
        seen.add(stage.name)
        if not math.isfinite(stage.timeout) or stage.timeout <= 0:
            raise PolicyError(f"{stage.name} timeout must be finite and greater than zero")
        if not math.isfinite(stage.grace) or stage.grace <= 0:
            raise PolicyError(f"{stage.name} grace must be finite and greater than zero")


validate_stage_registry(STAGES)
STAGE_BY_NAME = {stage.name: stage for stage in STAGES}


def stage_names_for_mode(mode: Mode) -> Tuple[str, ...]:
    return tuple(stage.name for stage in STAGES if mode in stage.modes)


def full_sha(raw: Optional[str], label: str) -> Optional[str]:
    if raw is None:
        return None
    if FULL_SHA_RE.fullmatch(raw) is None:
        raise PolicyError(f"{label} must be a lowercase full 40-hex SHA")
    return raw


def normalize_root(path: Path) -> Path:
    return path.expanduser().resolve()


def parse_request(argv: Optional[Sequence[str]]) -> QualityRequest:
    parser = argparse.ArgumentParser(description="Run repository quality gates.")
    parser.add_argument("--mode", choices=[mode.value for mode in Mode], required=True)
    parser.add_argument("--candidate-root", type=Path, default=POLICY_ROOT)
    parser.add_argument("--candidate-sha")
    parser.add_argument("--base-sha")
    parser.add_argument(
        "--hosted-context",
        choices=[context.value for context in HostedContext],
    )
    parser.add_argument("--stage", action="append", default=[])
    parser.add_argument("--list-stages", action="store_true")
    try:
        args = parser.parse_args(argv)
        mode = Mode(args.mode)
        hosted_context = (
            HostedContext(args.hosted_context) if args.hosted_context is not None else None
        )
        candidate_sha = full_sha(args.candidate_sha, "candidate-sha")
        base_sha = full_sha(args.base_sha, "base-sha")
        if mode is Mode.LOCAL and hosted_context is not None:
            raise PolicyError("local mode must not set --hosted-context")
        if mode is Mode.HOSTED and not args.list_stages:
            if hosted_context is None:
                raise PolicyError("hosted mode requires --hosted-context")
            if candidate_sha is None:
                raise PolicyError("hosted mode requires --candidate-sha")
        requested_stages = tuple(args.stage)
        if mode is Mode.HOSTED and requested_stages:
            raise PolicyError("hosted mode does not accept --stage")
        if len(set(requested_stages)) != len(requested_stages):
            raise PolicyError("duplicate stage requested")
        unknown = [name for name in requested_stages if name not in STAGE_BY_NAME]
        if unknown:
            raise PolicyError(f"unknown stage: {unknown[0]}")
        incompatible = [
            name for name in requested_stages if mode not in STAGE_BY_NAME[name].modes
        ]
        if incompatible:
            raise PolicyError(f"stage incompatible with {mode.value}: {incompatible[0]}")
    except SystemExit as error:
        raise PolicyError(f"invalid arguments: {error.code}") from None

    selected = requested_stages or stage_names_for_mode(mode)
    return QualityRequest(
        mode=mode,
        hosted_context=hosted_context,
        policy_root=POLICY_ROOT,
        candidate_root=normalize_root(args.candidate_root),
        candidate_sha=candidate_sha,
        base_sha=base_sha,
        stages=selected,
        list_stages=args.list_stages,
    )


def git_output(args: Tuple[str, ...], cwd: Path) -> str:
    try:
        completed = subprocess.run(
            ("/usr/bin/git",) + GIT_CONFIG_OVERRIDES + args,
            cwd=str(cwd),
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
            env=GIT_ENVIRONMENT,
        )
    except subprocess.TimeoutExpired as error:
        raise PolicyError("git command timed out") from error
    except OSError as error:
        raise PolicyError("git failed to start") from error
    if completed.returncode != 0:
        raise PolicyError("git command failed")
    return completed.stdout.strip()


def validate_git_checkout(
    request: QualityRequest,
    git: Callable[[Tuple[str, ...], Path], str] = git_output,
) -> None:
    candidate_root = normalize_root(request.candidate_root)
    show_toplevel = Path(git(("rev-parse", "--show-toplevel"), candidate_root)).resolve()
    if show_toplevel != candidate_root:
        raise PolicyError("candidate-root must be the checkout root")

    head = git(("rev-parse", "HEAD"), candidate_root)
    if FULL_SHA_RE.fullmatch(head) is None:
        raise PolicyError("checkout HEAD must be a lowercase full SHA")
    if request.candidate_sha is not None and head != request.candidate_sha:
        raise PolicyError("candidate-sha does not match checkout HEAD")

    if request.mode is Mode.HOSTED:
        if request.hosted_context is None:
            raise PolicyError("hosted mode requires --hosted-context")
        status = git(("status", "--porcelain"), candidate_root)
        if status:
            raise PolicyError("hosted candidate checkout must be clean")
        policy_root = normalize_root(request.policy_root)
        if request.hosted_context is HostedContext.PULL_REQUEST:
            if candidate_root == policy_root:
                raise PolicyError("pull-request context requires a separate candidate checkout")
            if request.base_sha is None:
                raise PolicyError("pull-request context requires --base-sha")
        if request.hosted_context is HostedContext.TRUSTED_REF:
            if candidate_root != policy_root:
                raise PolicyError("trusted-ref context requires the same checkout")
            if request.base_sha is not None:
                raise PolicyError("trusted-ref context must not use --base-sha")
        if candidate_root != policy_root and request.base_sha is None:
            raise PolicyError("separate hosted candidate checkout requires --base-sha")
        policy_toplevel = Path(git(("rev-parse", "--show-toplevel"), policy_root)).resolve()
        if policy_toplevel != policy_root:
            raise PolicyError("trusted policy checkout must be the checkout root")
        policy_status = git(("status", "--porcelain"), policy_root)
        if policy_status:
            raise PolicyError("trusted policy checkout must be clean")
        if request.base_sha is not None:
            policy_head = git(("rev-parse", "HEAD"), policy_root)
            if policy_head != request.base_sha:
                raise PolicyError("base-sha does not match trusted driver checkout HEAD")


def child_status(returncode: int) -> int:
    return returncode if returncode >= 0 else 128 - returncode


def try_signal_group(process_group: int, sig: signal.Signals) -> bool:
    try:
        os.killpg(process_group, sig)
        return True
    except ProcessLookupError:
        return False


def signal_group(process_group: int, sig: signal.Signals) -> None:
    try_signal_group(process_group, sig)


def reap_leader(process: subprocess.Popen, grace: float) -> None:
    if process.returncode is not None:
        return
    try:
        process.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        process.kill()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass


def close_output(process: subprocess.Popen) -> None:
    if process.stdout is not None and not process.stdout.closed:
        process.stdout.close()


def drain_output(process: subprocess.Popen, grace: float) -> Tuple[Optional[bytes], bool]:
    close_output(process)
    try:
        process.wait(timeout=grace)
        return None, True
    except subprocess.TimeoutExpired:
        return None, False
    except OSError:
        reap_leader(process, grace)
        return None, process.returncode is not None


def kill_remaining_group(process: subprocess.Popen, sent_sigkill: List[bool]) -> None:
    if sent_sigkill[0]:
        return
    sent_sigkill[0] = try_signal_group(process.pid, signal.SIGKILL)


def stop_process_group(process: subprocess.Popen, grace: float, sent_sigkill: List[bool]) -> Optional[bytes]:
    signal_group(process.pid, signal.SIGTERM)
    output, complete = drain_output(process, grace)
    if not complete:
        kill_remaining_group(process, sent_sigkill)
        output, complete = drain_output(process, grace)
        if not complete:
            close_output(process)
            output = None
            reap_leader(process, grace)
    else:
        kill_remaining_group(process, sent_sigkill)
    return output


def stream_process_output(
    process: subprocess.Popen,
    timeout: float,
) -> Tuple[bytes, str]:
    if process.stdout is None:
        try:
            process.wait(timeout=timeout)
            return b"", "complete"
        except subprocess.TimeoutExpired:
            return b"", "timeout"

    descriptor = process.stdout.fileno()
    os.set_blocking(descriptor, False)
    output = bytearray()
    deadline = time.monotonic() + timeout
    selector = selectors.DefaultSelector()
    selector.register(descriptor, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return bytes(output), "timeout"
            events = selector.select(remaining)
            if not events:
                return bytes(output), "timeout"
            try:
                chunk = os.read(
                    descriptor,
                    min(65536, MAX_COMMAND_OUTPUT_BYTES - len(output) + 1),
                )
            except BlockingIOError:
                continue
            if chunk:
                if len(output) + len(chunk) > MAX_COMMAND_OUTPUT_BYTES:
                    return b"", "limit"
                output.extend(chunk)
                continue

            selector.unregister(descriptor)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return bytes(output), "timeout"
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                return bytes(output), "timeout"
            return bytes(output), "complete"
    finally:
        selector.close()
        close_output(process)


def validate_positive_seconds(value: float, label: str) -> None:
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{label} must be finite and greater than zero")


def run_command(
    command: Tuple[str, ...],
    cwd: Path,
    timeout: float,
    grace: float,
    env: Optional[dict[str, str]] = None,
) -> CommandResult:
    validate_positive_seconds(timeout, "timeout")
    validate_positive_seconds(grace, "grace")
    process_holder: List[Optional[subprocess.Popen]] = [None]
    requested_signal: List[Optional[int]] = [None]
    cleanup_active = [False]
    cleanup_sent_sigkill = [False]
    previous_handlers = {}
    output: Optional[bytes] = None
    status: int
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
    cancellation_masked = True

    def restore_child_mask() -> None:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def request_cancellation(signum: int, _frame: object) -> None:
        process = process_holder[0]
        if cleanup_active[0]:
            if requested_signal[0] is None:
                requested_signal[0] = signum
            if process is not None:
                try:
                    cleanup_sent_sigkill[0] = (
                        try_signal_group(process.pid, signal.SIGKILL)
                        or cleanup_sent_sigkill[0]
                    )
                except PermissionError:
                    pass
            return
        if requested_signal[0] is None:
            requested_signal[0] = signum
            raise CancellationRequested(signum)
        if process is not None:
            signal_group(process.pid, signal.SIGKILL)

    def cleanup_process(process: subprocess.Popen, cleanup_grace: float) -> Optional[bytes]:
        cleanup_active[0] = True
        cleanup_sent_sigkill[0] = False
        try:
            return stop_process_group(process, cleanup_grace, cleanup_sent_sigkill)
        finally:
            cleanup_active[0] = False

    try:
        try:
            process = subprocess.Popen(
                command,
                cwd=str(cwd),
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                preexec_fn=restore_child_mask,
            )
        except OSError as error:
            print(f"quality: failed to spawn {command[0]!r}: {error}", file=sys.stderr)
            return CommandResult(SPAWN_FAILURE_STATUS)

        process_holder[0] = process
        try:
            for cancellation_signal in CANCELLATION_SIGNALS:
                previous_handlers[cancellation_signal] = signal.signal(
                    cancellation_signal, request_cancellation
                )
            try:
                cancellation_masked = False
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                try:
                    output, outcome = stream_process_output(process, timeout)
                except subprocess.TimeoutExpired:
                    cleanup_process(process, grace)
                    output = None
                    if requested_signal[0] is not None:
                        status = 128 + requested_signal[0]
                    else:
                        status = TIMEOUT_STATUS
                else:
                    if outcome == "complete":
                        status = child_status(process.returncode)
                        kill_remaining_group(process, cleanup_sent_sigkill)
                    else:
                        cleanup_process(process, grace)
                        if requested_signal[0] is not None:
                            output = None
                            status = 128 + requested_signal[0]
                        elif outcome == "limit":
                            output = OUTPUT_LIMIT_DIAGNOSTIC
                            status = OUTPUT_LIMIT_STATUS
                        else:
                            output = None
                            status = TIMEOUT_STATUS
                signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
                cancellation_masked = True
            except CancellationRequested as cancellation:
                cleanup_process(process, grace)
                output = None
                status = 128 + cancellation.signum
            except subprocess.TimeoutExpired:
                cleanup_process(process, grace)
                output = None
                status = TIMEOUT_STATUS
            except BaseException:
                cleanup_process(process, grace)
                raise
        finally:
            if not cancellation_masked:
                signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
                cancellation_masked = True
            for cancellation_signal, previous_handler in previous_handlers.items():
                signal.signal(cancellation_signal, previous_handler)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    return CommandResult(status=status, output=output or b"")


def read_regular_file_no_follow(
    path: Path,
    after_open: Optional[Callable[[], None]] = None,
) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        raise AssertionFailure("swift test did not produce xUnit output") from error
    try:
        stat_result = os.fstat(descriptor)
        if not stat.S_ISREG(stat_result.st_mode):
            raise AssertionFailure("swift test did not produce xUnit output")
        size = stat_result.st_size
        if size == 0:
            raise AssertionFailure("swift test xUnit output is empty")
        if size > MAX_XUNIT_BYTES:
            raise AssertionFailure("swift test xUnit output is too large")
        if after_open is not None:
            after_open()
        chunks = []
        remaining = MAX_XUNIT_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(payload) != size:
        raise AssertionFailure("swift test xUnit output changed while being read")
    if len(payload) > MAX_XUNIT_BYTES:
        raise AssertionFailure("swift test xUnit output is too large")
    return payload


def assert_xunit_has_tests(
    path: Path,
    after_open: Optional[Callable[[], None]] = None,
) -> int:
    payload = read_regular_file_no_follow(path, after_open=after_open)
    lowered = payload.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        raise AssertionFailure("swift test xUnit output contains unsafe XML constructs")
    testcase_count = 0
    try:
        for _event, element in ET.iterparse(io.BytesIO(payload), events=("end",)):
            if element.tag.split("}", 1)[-1] == "testcase":
                has_skipped = any(
                    child.tag.split("}", 1)[-1] == "skipped" for child in element
                )
                if not has_skipped:
                    testcase_count += 1
            element.clear()
    except ET.ParseError as error:
        raise AssertionFailure("swift test xUnit output is malformed") from error
    if testcase_count == 0:
        raise AssertionFailure("swift test xUnit output contains no executed tests")
    return testcase_count


def xunit_output_path(command: Sequence[str]) -> Path:
    prefix = "--xunit-output="
    values = [argument[len(prefix):] for argument in command if argument.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise AssertionFailure("swift test stage has an invalid xUnit output argument")
    return Path(values[0])


def default_runner(
    stage: Stage,
    command: Tuple[str, ...],
    cwd: Path,
    timeout: float,
    grace: float,
    env: dict[str, str],
) -> CommandResult:
    print(f"quality: running {stage.name}", file=sys.stderr)
    return run_command(command, cwd, timeout, grace, env)


def emit_stage_names(names: Iterable[str]) -> Tuple[str, ...]:
    captured = tuple(names)
    for name in captured:
        print(name)
    return captured


def validate_hosted_runner_context(
    request: QualityRequest,
    environment: dict[str, str],
) -> None:
    if request.mode is not Mode.HOSTED:
        return
    # Workflow governance must keep this required check on a GitHub-hosted macOS
    # runner. This runtime assertion prevents fork code from reaching an operator,
    # self-hosted, or TCC-enabled machine if the workflow is miswired later.
    required = {
        "GITHUB_ACTIONS": "true",
        "RUNNER_OS": "macOS",
        "RUNNER_ENVIRONMENT": "github-hosted",
    }
    if any(environment.get(name) != value for name, value in required.items()):
        raise PolicyError("hosted mode requires a GitHub-hosted macOS runner")


def _run_quality_request(
    request: QualityRequest,
    runner: Callable[[Stage, Tuple[str, ...], Path, float, float, dict[str, str]], CommandResult] = default_runner,
    git_validator: Callable[[QualityRequest], None] = validate_git_checkout,
    environment: Optional[dict[str, str]] = None,
) -> QualityResult:
    stderr: List[str] = []
    try:
        base_environment = dict(environment if environment is not None else os.environ)
        validate_hosted_runner_context(request, base_environment)
        git_validator(request)
        selected = [stage for stage in STAGES if stage.name in request.stages]
        with tempfile.TemporaryDirectory(prefix="apple-cli-quality-") as tempdir:
            xunit_dir = Path(tempdir)

            def execute_stage(stage: Stage) -> Optional[QualityResult]:
                command = stage.command(
                    request.policy_root,
                    request.candidate_root,
                    xunit_dir,
                )
                stage_env = base_environment.copy()
                if stage.isolated_home:
                    isolated_root = xunit_dir / stage.name
                    isolated_paths = {
                        "HOME": isolated_root / "home",
                        "TMPDIR": isolated_root / "tmp",
                        "XDG_CONFIG_HOME": isolated_root / "config",
                        "XDG_CACHE_HOME": isolated_root / "cache",
                        "XDG_DATA_HOME": isolated_root / "data",
                    }
                    for path in isolated_paths.values():
                        path.mkdir(parents=True, mode=0o700)
                    stage_env.update(
                        {name: str(path) for name, path in isolated_paths.items()}
                    )
                    stage_env["CFFIXED_USER_HOME"] = stage_env["HOME"]
                result = runner(
                    stage,
                    command,
                    request.candidate_root,
                    stage.timeout,
                    stage.grace,
                    stage_env,
                )
                suppress_output = result.status in (
                    TIMEOUT_STATUS,
                    128 + signal.SIGTERM,
                    128 + signal.SIGINT,
                    128 + signal.SIGHUP,
                )
                if result.output and not suppress_output:
                    sys.stdout.buffer.write(result.output)
                    sys.stdout.buffer.flush()
                if result.status != 0:
                    stderr.append(f"{stage.name} failed with status {result.status}")
                    return QualityResult(result.status, stderr=tuple(stderr))
                if stage.requires_xunit:
                    xunit_path = xunit_output_path(command)
                    count = assert_xunit_has_tests(xunit_path)
                    line = f"{stage.name}: {count} executed tests"
                    print(line, file=sys.stderr)
                    stderr.append(line)
                return None

            for stage in selected:
                if stage.name in ("bats-local", "bats-hosted"):
                    git_validator(request)
                    inventory_failure = execute_stage(STAGE_BY_NAME["bats-inventory"])
                    if inventory_failure is not None:
                        return inventory_failure
                failure = execute_stage(stage)
                if failure is not None:
                    return failure
    except PolicyError as error:
        print(f"quality: policy error: {error}", file=sys.stderr)
        return QualityResult(POLICY_FAILURE_STATUS, stderr=(str(error),))
    except AssertionFailure as error:
        print(f"quality: assertion failed: {error}", file=sys.stderr)
        return QualityResult(ASSERTION_FAILURE_STATUS, stderr=(str(error),))
    return QualityResult(0, stderr=tuple(stderr))


def run_quality(
    argv: Optional[Sequence[str]] = None,
    runner: Callable[[Stage, Tuple[str, ...], Path, float, float, dict[str, str]], CommandResult] = default_runner,
    git_validator: Callable[[QualityRequest], None] = validate_git_checkout,
    stdout: Callable[[Iterable[str]], object] = tuple,
) -> QualityResult:
    try:
        request = parse_request(argv)
        if request.list_stages:
            listed = stage_names_for_mode(request.mode)
            emitted = stdout(listed)
            if emitted is None:
                emitted = listed
            return QualityResult(0, stdout=listed)
    except PolicyError as error:
        print(f"quality: policy error: {error}", file=sys.stderr)
        return QualityResult(POLICY_FAILURE_STATUS, stderr=(str(error),))
    return _run_quality_request(
        request,
        runner=runner,
        git_validator=git_validator,
        environment=os.environ.copy(),
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    return run_quality(argv, stdout=emit_stage_names).status


if __name__ == "__main__":
    raise SystemExit(main())
